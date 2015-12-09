// MARK: - PersistenceError

/// An error thrown by a type that adopts DatabasePersistable.
public enum PersistenceError: ErrorType {
    
    /// Thrown by DatabasePersistable.update() when no matching row could be
    /// found in the database.
    case NotFound(DatabasePersistable)
}

extension PersistenceError : CustomStringConvertible {
    /// A textual representation of `self`.
    public var description: String {
        switch self {
        case .NotFound(let persistable):
            return "Not found: \(persistable)"
        }
    }
}

// MARK: - DatabasePersistable

/// Types that adopt DatabasePersistable can be inserted, updated, and deleted.
public protocol DatabasePersistable : DatabaseTableMapping {
    
    /// Returns the values that should be stored in the database.
    ///
    /// Keys of the returned dictionary must match the column names of the
    /// target database table (see DatabaseTableMapping.databaseTableName()).
    ///
    /// In particular, primary key columns, if any, must be included.
    ///
    ///     struct Person : DatabasePersistable {
    ///         var id: Int64?
    ///         var name: String?
    ///
    ///         var storedDatabaseDictionary: [String: DatabaseValueConvertible?] {
    ///             return ["id": id, "name": name]
    ///         }
    ///     }
    var storedDatabaseDictionary: [String: DatabaseValueConvertible?] { get }
    
    /// If the underlying database table has an INTEGER PRIMARY KEY, this method
    /// is called after a successful insertion. Adopting type may implement this
    /// method and update their primary key accordingly.
    ///
    /// This method is optional: the default implementation does nothing.
    ///
    ///     struct Person : DatabasePersistable {
    ///         var id: Int64?
    ///         var name: String?
    ///
    ///         mutating func didInsertWithRowID(rowID: Int64, forColumn name: String) {
    ///             self.id = rowID
    ///         }
    ///     }
    mutating func didInsertWithRowID(rowID: Int64, forColumn name: String)
}

public extension DatabasePersistable {
    
    /// The default implementation does nothing.
    mutating func didInsertWithRowID(rowID: Int64, forColumn name: String) {
    }
    
    // MARK: - CRUD
    
    /// Executes an INSERT statement.
    ///
    /// On success, this method sets the *databaseEdited* flag to false.
    ///
    /// This method is guaranteed to have inserted a row in the database if it
    /// returns without error.
    ///
    /// When the table has an INTEGER PRIMARY KEY, the
    /// didInsertWithRowID(:forColumn:) method is called upon successful
    /// insertion.
    ///
    /// - parameter db: A Database.
    /// - throws: A DatabaseError whenever a SQLite error occurs.
    mutating func insert(db: Database) throws {
        let dataMapper = DataMapper(db, self)
        let changes = try dataMapper.insertStatement().execute()
        if case .Managed(let rowIDColumnName) = dataMapper.primaryKey {
            didInsertWithRowID(changes.insertedRowID!, forColumn: rowIDColumnName)
        }
    }
    
    /// Executes an UPDATE statement.
    ///
    /// This method is guaranteed to have updated a row in the database if it
    /// returns without error.
    ///
    /// - parameter db: A Database.
    /// - throws: A DatabaseError is thrown whenever a SQLite error occurs.
    ///   PersistenceError.NotFound is thrown if the primary key does not
    ///   match any row in the database.
    func update(db: Database) throws {
        let changes = try DataMapper(db, self).updateStatement().execute()
        if changes.changedRowCount == 0 {
            throw PersistenceError.NotFound(self)
        }
    }
    
    /// Executes a DELETE statement.
    ///
    /// - parameter db: A Database.
    /// - returns: Whether a database row was deleted.
    /// - throws: A DatabaseError is thrown whenever a SQLite error occurs.
    func delete(db: Database) throws -> Bool {
        return try DataMapper(db, self).deleteStatement().execute().changedRowCount > 0
    }
    
    /// Returns true if and only if the primary key matches a row in
    /// the database.
    ///
    /// - parameter db: A Database.
    /// - returns: Whether the primary key matches a row in the database.
    func exists(db: Database) -> Bool {
        return (Row.fetchOne(DataMapper(db, self).existsStatement()) != nil)
    }
}


// MARK: - DataMapper

/// DataMapper takes care of DatabasePersistable CRUD
final class DataMapper {
    
    /// The database
    let db: Database
    
    /// The persistable
    let persistable: DatabasePersistable
    
    /// DataMapper keeps a copy the persistable's storedDatabaseDictionary, so
    /// that this dictionary is built once whatever the database operation.
    /// It is guaranteed to have at least one (key, value) pair.
    let storedDatabaseDictionary: [String: DatabaseValueConvertible?]
    
    /// The table name
    let databaseTableName: String
    
    /// The table primary key
    let primaryKey: PrimaryKey
    
    /// An excerpt from storedDatabaseDictionary whose keys are primary key
    /// columns.
    ///
    /// It is nil when persistable has no primary key.
    lazy var primaryKeyDictionary: [String: DatabaseValueConvertible?]? = { [unowned self] in
        let columns = self.primaryKey.columns
        guard columns.count > 0 else {
            return nil
        }
        let storedDatabaseDictionary = self.storedDatabaseDictionary
        var dictionary: [String: DatabaseValueConvertible?] = [:]
        for column in columns {
            dictionary[column] = storedDatabaseDictionary[column]
        }
        return dictionary
        }()
    
    /// An excerpt from storedDatabaseDictionary whose keys are primary key
    /// columns. It is able to resolve a row in the database.
    ///
    /// It is nil when the primaryKeyDictionary is nil or unable to identify a
    /// row in the database.
    lazy var resolvingPrimaryKeyDictionary: [String: DatabaseValueConvertible?]? = { [unowned self] in
        // IMPLEMENTATION NOTE
        //
        // https://www.sqlite.org/lang_createtable.html
        //
        // > According to the SQL standard, PRIMARY KEY should always
        // > imply NOT NULL. Unfortunately, due to a bug in some early
        // > versions, this is not the case in SQLite. Unless the column
        // > is an INTEGER PRIMARY KEY or the table is a WITHOUT ROWID
        // > table or the column is declared NOT NULL, SQLite allows
        // > NULL values in a PRIMARY KEY column. SQLite could be fixed
        // > to conform to the standard, but doing so might break legacy
        // > applications. Hence, it has been decided to merely document
        // > the fact that SQLite allowing NULLs in most PRIMARY KEY
        // > columns.
        //
        // What we implement: we consider that the primary key is missing if
        // and only if *all* columns of the primary key are NULL.
        //
        // For tables with a single column primary key, we comply to the
        // SQL standard.
        //
        // For tables with multi-column primary keys, we let the user
        // store NULL in all but one columns of the primary key.
        
        guard let dictionary = self.primaryKeyDictionary else {
            return nil
        }
        for case let value? in dictionary.values {
            return dictionary
        }
        return nil
        }()
    
    
    // MARK: - Initializer
    
    init(_ db: Database, _ persistable: DatabasePersistable) {
        // Fail early if databaseTable is nil
        guard let databaseTableName = persistable.dynamicType.databaseTableName() else {
            fatalError("Nil returned from \(persistable.dynamicType).databaseTableName()")
        }

        // Fail early if database table does not exist.
        guard let primaryKey = db.primaryKeyForTable(named: databaseTableName) else {
            fatalError("Table \(databaseTableName.quotedDatabaseIdentifier) does not exist. See \(persistable.dynamicType).databaseTableName()")
        }

        // Fail early if storedDatabaseDictionary is empty
        let storedDatabaseDictionary = persistable.storedDatabaseDictionary
        guard storedDatabaseDictionary.count > 0 else {
            fatalError("Invalid empty dictionary returned from \(persistable.dynamicType).storedDatabaseDictionary")
        }
        
        self.db = db
        self.persistable = persistable
        self.storedDatabaseDictionary = storedDatabaseDictionary
        self.databaseTableName = databaseTableName
        self.primaryKey = primaryKey
    }
    
    
    // MARK: - Statement builders
    
    func insertStatement() -> UpdateStatement {
        let insertStatement = db.updateStatement(DataMapper.insertSQL(tableName: databaseTableName, insertedColumns: Array(storedDatabaseDictionary.keys)))
        insertStatement.arguments = StatementArguments(storedDatabaseDictionary.values)
        return insertStatement
    }
    
    func updateStatement() -> UpdateStatement {
        // Fail early if primary key does not resolve to a database row.
        guard let primaryKeyDictionary = resolvingPrimaryKeyDictionary else {
            fatalError("Invalid primary key in \(persistable)")
        }
        
        // Don't update primary key columns
        var updatedDictionary = storedDatabaseDictionary
        for column in primaryKeyDictionary.keys {
            updatedDictionary.removeValueForKey(column)
        }
        
        // We need something to update.
        if updatedDictionary.count == 0 {
            // IMPLEMENTATION NOTE
            //
            // It is important to update something, so that
            // TransactionObserverType can observe a change even though this
            // change is useless.
            //
            // The goal is to be able to write tests with minimal tables,
            // including tables made of a single primary key column.
            updatedDictionary = storedDatabaseDictionary
        }
        
        // Update
        let updateStatement = db.updateStatement(DataMapper.updateSQL(tableName: databaseTableName, updatedColumns: Array(updatedDictionary.keys), conditionColumns: Array(primaryKeyDictionary.keys)))
        updateStatement.arguments = StatementArguments(Array(updatedDictionary.values) + Array(primaryKeyDictionary.values))
        return updateStatement
    }
    
    func deleteStatement() -> UpdateStatement {
        // Fail early if primary key does not resolve to a database row.
        guard let primaryKeyDictionary = resolvingPrimaryKeyDictionary else {
            fatalError("Invalid primary key in \(persistable)")
        }
        
        // Delete
        let deleteStatement = db.updateStatement(DataMapper.deleteSQL(tableName: databaseTableName, conditionColumns: Array(primaryKeyDictionary.keys)))
        deleteStatement.arguments = StatementArguments(primaryKeyDictionary.values)
        return deleteStatement
    }
    
    func reloadStatement() -> SelectStatement {
        // Fail early if primary key does not resolve to a database row.
        guard let primaryKeyDictionary = resolvingPrimaryKeyDictionary else {
            fatalError("Invalid primary key in \(persistable)")
        }
        
        // Fetch
        let reloadStatement = db.selectStatement(DataMapper.reloadSQL(tableName: databaseTableName, conditionColumns: Array(primaryKeyDictionary.keys)))
        reloadStatement.arguments = StatementArguments(primaryKeyDictionary.values)
        return reloadStatement
    }
    
    /// SELECT statement that returns a row if and only if the primary key
    /// matches a row in the database.
    func existsStatement() -> SelectStatement {
        // Fail early if primary key does not resolve to a database row.
        guard let primaryKeyDictionary = resolvingPrimaryKeyDictionary else {
            fatalError("Invalid primary key in \(persistable)")
        }
        
        // Fetch
        let existsStatement = db.selectStatement(DataMapper.existsSQL(tableName: databaseTableName, conditionColumns: Array(primaryKeyDictionary.keys)))
        existsStatement.arguments = StatementArguments(primaryKeyDictionary.values)
        return existsStatement
    }
    
    
    // MARK: - SQL query builders
    
    private class func insertSQL(tableName tableName: String, insertedColumns: [String]) -> String {
        let columnSQL = insertedColumns.map { $0.quotedDatabaseIdentifier }.joinWithSeparator(",")
        let valuesSQL = Array(count: insertedColumns.count, repeatedValue: "?").joinWithSeparator(",")
        return "INSERT INTO \(tableName.quotedDatabaseIdentifier) (\(columnSQL)) VALUES (\(valuesSQL))"
    }
    
    private class func updateSQL(tableName tableName: String, updatedColumns: [String], conditionColumns: [String]) -> String {
        let updateSQL = updatedColumns.map { "\($0.quotedDatabaseIdentifier)=?" }.joinWithSeparator(",")
        return "UPDATE \(tableName.quotedDatabaseIdentifier) SET \(updateSQL) WHERE \(whereSQL(conditionColumns))"
    }
    
    private class func deleteSQL(tableName tableName: String, conditionColumns: [String]) -> String {
        return "DELETE FROM \(tableName.quotedDatabaseIdentifier) WHERE \(whereSQL(conditionColumns))"
    }
    
    private class func existsSQL(tableName tableName: String, conditionColumns: [String]) -> String {
        return "SELECT 1 FROM \(tableName.quotedDatabaseIdentifier) WHERE \(whereSQL(conditionColumns))"
    }

    private class func reloadSQL(tableName tableName: String, conditionColumns: [String]) -> String {
        return "SELECT * FROM \(tableName.quotedDatabaseIdentifier) WHERE \(whereSQL(conditionColumns))"
    }
    
    private class func whereSQL(conditionColumns: [String]) -> String {
        return conditionColumns.map { "\($0.quotedDatabaseIdentifier)=?" }.joinWithSeparator(" AND ")
    }
}