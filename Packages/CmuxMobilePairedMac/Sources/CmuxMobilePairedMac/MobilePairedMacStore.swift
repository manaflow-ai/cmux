public import CMUXMobileCore
public import Foundation
import SQLite3
import os

private let pairedMacStoreLog = Logger(subsystem: "com.cmuxterm.app", category: "PairedMacStore")

/// SQLite-backed store of paired Macs. Schema migrations gated on
/// `PRAGMA user_version`.
///
/// An `actor` serializes all access to the (non-`Sendable`, not-thread-safe)
/// SQLite connection, so it is genuinely `Sendable` without opting out of
/// concurrency checking. Construct it once at the app composition root and
/// inject it as `any MobilePairedMacStoring`.
public actor MobilePairedMacStore: MobilePairedMacStoring {
    /// The schema version this build creates and migrates to.
    public static let currentSchemaVersion: Int32 = 1

    private let dbPath: String
    // `nonisolated(unsafe)` only so the (Swift 6 nonisolated) `deinit` can close
    // the handle. Every other access goes through actor-isolated methods, and
    // the connection itself is opened `SQLITE_OPEN_FULLMUTEX`, so this is safe.
    nonisolated(unsafe) private var db: OpaquePointer?

    /// The default on-disk location for the paired-Mac database.
    /// - Parameter fileManager: File manager used to resolve and create the directory.
    /// - Returns: The `paired-macs.sqlite3` URL under Application Support/cmux.
    /// - Throws: Any error thrown while resolving or creating the directory.
    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("cmux", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("paired-macs.sqlite3")
    }

    /// Open (creating if needed) the store at the given database URL.
    /// - Parameter databaseURL: On-disk SQLite file location.
    /// - Throws: ``MobilePairedMacStoreError`` if the connection cannot be opened.
    public init(databaseURL: URL) throws {
        self.dbPath = databaseURL.path
        self.db = try Self.openConnection(path: databaseURL.path)
    }

    /// Open the store at ``defaultDatabaseURL(fileManager:)``.
    /// - Throws: ``MobilePairedMacStoreError`` if the connection cannot be opened.
    public init() throws {
        try self.init(databaseURL: Self.defaultDatabaseURL())
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Open + migrate

    /// Open the SQLite connection and set connection pragmas. `nonisolated`
    /// `static` so the actor's synchronous initializer can build the handle
    /// without hopping isolation. Opened with `SQLITE_OPEN_FULLMUTEX` so SQLite
    /// serializes access internally; the actor adds an outer serialization layer.
    /// Schema migration runs lazily on first store access via `ensureReady()`.
    private nonisolated static func openConnection(path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw MobilePairedMacStoreError.openFailed(rc)
        }
        for pragma in ["PRAGMA foreign_keys = ON;", "PRAGMA journal_mode = WAL;"] {
            let prc = sqlite3_exec(handle, pragma, nil, nil, nil)
            guard prc == SQLITE_OK else {
                sqlite3_close_v2(handle)
                throw MobilePairedMacStoreError.stepFailed(prc, "")
            }
        }
        return handle
    }

    private var didMigrate = false

    /// Run schema migrations exactly once, on first store access (actor-isolated).
    private func ensureReady() throws {
        guard !didMigrate else { return }
        try runMigrations()
        didMigrate = true
    }

    private func runMigrations() throws {
        let version = try userVersion()
        switch version {
        case 0:
            try migrateToV1()
            try setUserVersion(1)
            fallthrough
        case 1:
            break
        default:
            // Future schema; fail closed so we don't corrupt on downgrade.
            throw MobilePairedMacStoreError.unknownSchemaVersion(Int(version))
        }
    }

    private func migrateToV1() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS paired_macs (
                mac_device_id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT,
                stack_user_id TEXT,
                created_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 0
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_macs_stack_user ON paired_macs(stack_user_id);")
        try exec("""
            CREATE TABLE IF NOT EXISTS mac_routes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mac_device_id TEXT NOT NULL,
                route_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                endpoint_json TEXT NOT NULL,
                priority INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (mac_device_id) REFERENCES paired_macs(mac_device_id) ON DELETE CASCADE
            );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_routes_device ON mac_routes(mac_device_id);")
    }

    // MARK: - Public API

    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        markActive: Bool,
        stackUserID: String?,
        now: Date = Date()
    ) throws {
        try ensureReady()
        try transaction {
            if markActive {
                let scope = stackUserID.map(BindValue.text) ?? .null
                if stackUserID != nil {
                    try exec("UPDATE paired_macs SET is_active = 0 WHERE stack_user_id IS ?;",
                             binding: [scope])
                } else {
                    try exec("UPDATE paired_macs SET is_active = 0;")
                }
            }
            let existing = try fetchMacRow(macDeviceID: macDeviceID)
            let createdAt = existing?.createdAt ?? now
            try upsertMacRow(
                macDeviceID: macDeviceID,
                displayName: displayName,
                stackUserID: stackUserID,
                createdAt: createdAt,
                lastSeenAt: now,
                isActive: markActive
            )
            try exec("DELETE FROM mac_routes WHERE mac_device_id = ?;", binding: [.text(macDeviceID)])
            for route in routes {
                let encoded = try Self.encodeRoute(route)
                try exec("""
                    INSERT INTO mac_routes (mac_device_id, route_id, kind, endpoint_json, priority)
                    VALUES (?, ?, ?, ?, ?);
                """, binding: [
                    .text(macDeviceID),
                    .text(route.id),
                    .text(route.kind.rawValue),
                    .text(encoded),
                    .int(Int64(route.priority)),
                ])
            }
        }
    }

    public func loadAll(stackUserID: String? = nil) throws -> [MobilePairedMac] {
        try ensureReady()
        return try fetchAllMacs(stackUserID: stackUserID)
    }

    public func activeMac(stackUserID: String? = nil) throws -> MobilePairedMac? {
        try ensureReady()
        return try fetchAllMacs(activeOnly: true, stackUserID: stackUserID).first
    }

    public func setActive(macDeviceID: String) throws {
        try ensureReady()
        try transaction {
            // Clear the active flag only within the target Mac's own Stack-user
            // scope, mirroring the scoped clear in `upsert`. On a shared device
            // (more than one Stack user has pairings), switching hosts for one
            // signed-in user must not wipe another user's active Mac, or that
            // user fails to auto-reconnect after signing back in. `IS` is
            // SQLite's null-safe equality, so a NULL-scoped target clears only
            // other NULL-scoped rows.
            try exec("""
                UPDATE paired_macs SET is_active = 0
                WHERE stack_user_id IS (
                    SELECT stack_user_id FROM paired_macs WHERE mac_device_id = ?
                );
                """,
                binding: [.text(macDeviceID)])
            try exec("UPDATE paired_macs SET is_active = 1 WHERE mac_device_id = ?;",
                     binding: [.text(macDeviceID)])
        }
    }

    public func remove(macDeviceID: String) throws {
        try ensureReady()
        try exec("DELETE FROM paired_macs WHERE mac_device_id = ?;",
                 binding: [.text(macDeviceID)])
    }

    public func removeAll() throws {
        try ensureReady()
        try exec("DELETE FROM paired_macs;")
    }

    // MARK: - Internals

    private func userVersion() throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
        return sqlite3_column_int(statement, 0)
    }

    private func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version = \(version);")
    }

    private struct MacRow {
        let macDeviceID: String
        let displayName: String?
        let stackUserID: String?
        let createdAt: Date
        let lastSeenAt: Date
        let isActive: Bool
    }

    private func fetchMacRow(macDeviceID: String) throws -> MacRow? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT display_name, stack_user_id, created_at, last_seen_at, is_active
            FROM paired_macs WHERE mac_device_id = ?;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: [.text(macDeviceID)])
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
        let displayName = Self.readNullableText(statement, column: 0)
        let stackUserID = Self.readNullableText(statement, column: 1)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        let lastSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        let isActive = sqlite3_column_int(statement, 4) != 0
        return MacRow(
            macDeviceID: macDeviceID,
            displayName: displayName,
            stackUserID: stackUserID,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            isActive: isActive
        )
    }

    private func upsertMacRow(
        macDeviceID: String,
        displayName: String?,
        stackUserID: String?,
        createdAt: Date,
        lastSeenAt: Date,
        isActive: Bool
    ) throws {
        try exec("""
            INSERT INTO paired_macs (mac_device_id, display_name, stack_user_id, created_at, last_seen_at, is_active)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(mac_device_id) DO UPDATE SET
                display_name = excluded.display_name,
                stack_user_id = excluded.stack_user_id,
                last_seen_at = excluded.last_seen_at,
                is_active = excluded.is_active;
        """, binding: [
            .text(macDeviceID),
            displayName.map(BindValue.text) ?? .null,
            stackUserID.map(BindValue.text) ?? .null,
            .real(createdAt.timeIntervalSince1970),
            .real(lastSeenAt.timeIntervalSince1970),
            .int(isActive ? 1 : 0),
        ])
    }

    private func fetchAllMacs(activeOnly: Bool = false, stackUserID: String? = nil) throws -> [MobilePairedMac] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        var clauses: [String] = []
        var bindings: [BindValue] = []
        if activeOnly {
            clauses.append("is_active = 1")
        }
        if let stackUserID {
            clauses.append("stack_user_id IS ?")
            bindings.append(.text(stackUserID))
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT mac_device_id, display_name, stack_user_id, created_at, last_seen_at, is_active
            FROM paired_macs
            \(whereClause)
            ORDER BY last_seen_at DESC;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: bindings)
        var rows: [MacRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let macDeviceID = String(cString: cString)
            let displayName = Self.readNullableText(statement, column: 1)
            let storedStackUserID = Self.readNullableText(statement, column: 2)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let lastSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let isActive = sqlite3_column_int(statement, 5) != 0
            rows.append(MacRow(
                macDeviceID: macDeviceID,
                displayName: displayName,
                stackUserID: storedStackUserID,
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                isActive: isActive
            ))
        }

        return try rows.map { row in
            let routes = try fetchRoutes(macDeviceID: row.macDeviceID)
            return MobilePairedMac(
                macDeviceID: row.macDeviceID,
                displayName: row.displayName,
                routes: routes,
                createdAt: row.createdAt,
                lastSeenAt: row.lastSeenAt,
                isActive: row.isActive,
                stackUserID: row.stackUserID
            )
        }
    }

    private func fetchRoutes(macDeviceID: String) throws -> [CmxAttachRoute] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT endpoint_json
            FROM mac_routes
            WHERE mac_device_id = ?
            ORDER BY priority ASC, id ASC;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: [.text(macDeviceID)])

        var routes: [CmxAttachRoute] = []
        let decoder = JSONDecoder()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else { continue }
            let json = String(cString: cString)
            guard let data = json.data(using: .utf8),
                  let route = try? decoder.decode(CmxAttachRoute.self, from: data) else {
                pairedMacStoreLog.warning("dropping unparsable route row")
                continue
            }
            routes.append(route)
        }
        return routes
    }

    private static func encodeRoute(_ route: CmxAttachRoute) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(route)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MobilePairedMacStoreError.decodeFailed
        }
        return string
    }

    private static func readNullableText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }

    // MARK: - Statement helpers

    private enum BindValue {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    private func exec(_ sql: String, binding parameters: [BindValue] = []) throws {
        if parameters.isEmpty {
            let rc = sqlite3_exec(db, sql, nil, nil, nil)
            guard rc == SQLITE_OK else {
                throw MobilePairedMacStoreError.stepFailed(rc, lastErrorMessage())
            }
            return
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: parameters)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
    }

    private func bind(statement: OpaquePointer?, parameters: [BindValue]) throws {
        for (index, value) in parameters.enumerated() {
            let pos = Int32(index + 1)
            let rc: Int32
            switch value {
            case .text(let s):
                rc = s.withCString { ptr in
                    // SQLITE_TRANSIENT == -1; sqlite3 needs to copy the buffer.
                    sqlite3_bind_text(statement, pos, ptr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .int(let i):
                rc = sqlite3_bind_int64(statement, pos, i)
            case .real(let d):
                rc = sqlite3_bind_double(statement, pos, d)
            case .null:
                rc = sqlite3_bind_null(statement, pos)
            }
            guard rc == SQLITE_OK else {
                throw MobilePairedMacStoreError.stepFailed(rc, lastErrorMessage())
            }
        }
    }

    private func transaction(_ block: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try block()
            try exec("COMMIT;")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func lastErrorMessage() -> String {
        guard let cString = sqlite3_errmsg(db) else { return "" }
        return String(cString: cString)
    }
}
