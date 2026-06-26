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
    public static let currentSchemaVersion: Int32 = 5

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
        // Each case applies its schema changes AND bumps `user_version` inside one
        // transaction, so a kill / disk-full / SQLite error mid-migration rolls the
        // whole step back (SQLite DDL and `PRAGMA user_version` are both
        // transactional). The store then reopens at the prior version and retries
        // the step cleanly instead of being stranded with a partially-applied
        // schema whose `user_version` never advanced.
        switch version {
        case 0:
            try transaction {
                try migrateToV1()
                try migrateToV2()
                try migrateToV3()
                try migrateToV4()
                try migrateToV5()
                try setUserVersion(5)
            }
        case 1:
            try transaction {
                try migrateToV2()
                try migrateToV3()
                try migrateToV4()
                try migrateToV5()
                try setUserVersion(5)
            }
        case 2:
            try transaction {
                try migrateToV3()
                try migrateToV4()
                try migrateToV5()
                try setUserVersion(5)
            }
        case 3:
            try transaction {
                try migrateToV4()
                try migrateToV5()
                try setUserVersion(5)
            }
        case 4:
            try transaction {
                try migrateToV5()
                try setUserVersion(5)
            }
        case 5:
            break
        default:
            // A newer build wrote a higher schema version. Schema migrations are
            // additive by contract — older builds keep reading the columns and
            // tables they already know (see
            // plans/feat-ios-paired-mac-backup/DESIGN.md §4 and the same
            // discipline in docs/presence-service.md). Throwing here would make
            // `ensureReady` fail and every read surface as a TOTAL loss of the
            // user's paired Macs across an upgrade-then-older-build open, even
            // though the v1 rows are intact on disk. Degrade gracefully instead:
            // leave `user_version` untouched (never write a destructive downgrade
            // marker) and read what this build understands. The DO backup is the
            // safety net if a future non-additive change ever makes the local
            // read genuinely fail.
            pairedMacStoreLog.warning(
                "paired-mac store schema v\(version) is newer than this build (v\(Self.currentSchemaVersion)); reading known columns only"
            )
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

    /// v2: user-editable, per-user-synced customizations (additive columns, all
    /// nullable so older rows and older builds are unaffected).
    ///
    /// Idempotent: only adds columns that are missing. The transactional
    /// `runMigrations` step already makes this restart-safe for new devices, but
    /// the column check also recovers any device that ran an earlier,
    /// non-transactional build of this migration and was left partially applied
    /// (some columns added, `user_version` still 1) — re-running here just adds
    /// the remaining columns instead of failing on a duplicate-column error.
    private func migrateToV2() throws {
        let existing = try tableColumns("paired_macs")
        for column in ["custom_name", "custom_color", "custom_icon"]
        where !existing.contains(column) {
            try exec("ALTER TABLE paired_macs ADD COLUMN \(column) TEXT;")
        }
    }

    /// v3: per-Stack-team scoping. The backup Durable Object is per-(account, team),
    /// so a row needs the team it belongs to. Additive + nullable: pre-v3 rows have
    /// `team_id = NULL` and stay visible under every team (a non-nil team filter is
    /// `team_id IS ? OR team_id IS NULL`) so an upgrade never hides existing hosts;
    /// they get stamped with the active team on the next upsert/route refresh.
    /// Idempotent, like ``migrateToV2``.
    private func migrateToV3() throws {
        let existing = try tableColumns("paired_macs")
        if !existing.contains("team_id") {
            try exec("ALTER TABLE paired_macs ADD COLUMN team_id TEXT;")
        }
        try exec("CREATE INDEX IF NOT EXISTS idx_macs_team ON paired_macs(stack_user_id, team_id);")
    }

    /// v4: make `(mac_device_id, stack_user_id, team_id)` the durable identity by
    /// adding a non-null normalized `owner_key` and carrying it into `mac_routes`.
    ///
    /// SQLite UNIQUE/PRIMARY KEY constraints treat NULL values as distinct, so a
    /// literal nullable composite key would still allow duplicate anonymous or
    /// team-less rows. `owner_key` is the normalized scope discriminator used only
    /// for constraints and foreign keys; the readable columns remain
    /// `stack_user_id` and `team_id`.
    private func migrateToV4() throws {
        let existing = try tableColumns("paired_macs")
        guard !existing.contains("owner_key") else { return }

        try exec("""
            CREATE TABLE paired_macs_v4 (
                mac_device_id TEXT NOT NULL,
                owner_key TEXT NOT NULL,
                display_name TEXT,
                stack_user_id TEXT,
                team_id TEXT,
                created_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                is_active INTEGER NOT NULL DEFAULT 0,
                custom_name TEXT,
                custom_color TEXT,
                custom_icon TEXT,
                PRIMARY KEY (mac_device_id, owner_key)
            );
        """)
        try exec("""
            INSERT INTO paired_macs_v4 (
                mac_device_id, owner_key, display_name, stack_user_id, team_id,
                created_at, last_seen_at, is_active, custom_name, custom_color, custom_icon
            )
            SELECT
                mac_device_id,
                IFNULL(stack_user_id, '') || char(31) || IFNULL(team_id, ''),
                display_name,
                stack_user_id,
                team_id,
                created_at,
                last_seen_at,
                is_active,
                custom_name,
                custom_color,
                custom_icon
            FROM paired_macs;
        """)
        try exec("""
            CREATE TABLE mac_routes_v4 (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mac_device_id TEXT NOT NULL,
                owner_key TEXT NOT NULL,
                route_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                endpoint_json TEXT NOT NULL,
                priority INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (mac_device_id, owner_key)
                    REFERENCES paired_macs_v4(mac_device_id, owner_key)
                    ON DELETE CASCADE
            );
        """)
        try exec("""
            INSERT INTO mac_routes_v4 (mac_device_id, owner_key, route_id, kind, endpoint_json, priority)
            SELECT
                routes.mac_device_id,
                IFNULL(macs.stack_user_id, '') || char(31) || IFNULL(macs.team_id, ''),
                routes.route_id,
                routes.kind,
                routes.endpoint_json,
                routes.priority
            FROM mac_routes routes
            JOIN paired_macs macs ON macs.mac_device_id = routes.mac_device_id;
        """)
        try exec("DROP TABLE mac_routes;")
        try exec("DROP TABLE paired_macs;")
        try exec("ALTER TABLE paired_macs_v4 RENAME TO paired_macs;")
        try exec("ALTER TABLE mac_routes_v4 RENAME TO mac_routes;")
        try exec("CREATE INDEX IF NOT EXISTS idx_macs_stack_user ON paired_macs(stack_user_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_macs_team ON paired_macs(stack_user_id, team_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_routes_device ON mac_routes(mac_device_id, owner_key);")
    }

    /// v5: local-only attach ticket state for fast reconnect without a Stack
    /// network round trip. These columns are intentionally not represented in the
    /// paired-Mac backup wire format.
    private func migrateToV5() throws {
        let existing = try tableColumns("paired_macs")
        if !existing.contains("attach_token") {
            try exec("ALTER TABLE paired_macs ADD COLUMN attach_token TEXT;")
        }
        if !existing.contains("attach_token_expires_at") {
            try exec("ALTER TABLE paired_macs ADD COLUMN attach_token_expires_at REAL;")
        }
    }

    /// Column names defined on `table` (via `PRAGMA table_info`), used to make
    /// additive column migrations idempotent.
    private func tableColumns(_ table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            // table_info columns: cid(0), name(1), type(2), notnull(3),
            // dflt_value(4), pk(5).
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns
    }

    // MARK: - Public API

    /// Insert or update one paired Mac within the explicit account/team owner scope.
    public func upsert(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        attachToken: String? = nil,
        attachTokenExpiresAt: Date? = nil,
        markActive: Bool,
        stackUserID: String?,
        teamID: String? = nil,
        now: Date = Date()
    ) throws {
        try ensureReady()
        try transaction {
            if markActive {
                try clearActiveMacs(stackUserID: stackUserID, teamID: teamID)
            }
            let ownerKey = "\(stackUserID ?? "")\u{1F}\(teamID ?? "")"
            let existing = try fetchMacRow(macDeviceID: macDeviceID, ownerKey: ownerKey)
            var claimedLegacy: MacRow?
            if existing == nil,
               teamID != nil,
               let legacy = try fetchMacRow(
                    macDeviceID: macDeviceID,
                    ownerKey: "\(stackUserID ?? "")\u{1F}"
               ) {
                try moveMacRowScope(
                    macDeviceID: macDeviceID,
                    fromOwnerKey: legacy.ownerKey,
                    toOwnerKey: ownerKey,
                    teamID: teamID
                )
                claimedLegacy = legacy
            }
            let createdAt = existing?.createdAt ?? claimedLegacy?.createdAt ?? now
            try upsertMacRow(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                displayName: displayName,
                stackUserID: stackUserID,
                teamID: teamID,
                attachToken: attachToken,
                attachTokenExpiresAt: attachTokenExpiresAt,
                createdAt: createdAt,
                lastSeenAt: now,
                isActive: markActive
            )
            try exec(
                "DELETE FROM mac_routes WHERE mac_device_id = ? AND owner_key = ?;",
                binding: [.text(macDeviceID), .text(ownerKey)]
            )
            for route in routes {
                let encoded = try Self.encodeRoute(route)
                try exec("""
                    INSERT INTO mac_routes (mac_device_id, owner_key, route_id, kind, endpoint_json, priority)
                    VALUES (?, ?, ?, ?, ?, ?);
                """, binding: [
                    .text(macDeviceID),
                    .text(ownerKey),
                    .text(route.id),
                    .text(route.kind.rawValue),
                    .text(encoded),
                    .int(Int64(route.priority)),
                ])
            }
        }
    }

    /// Load every paired Mac visible to the optional Stack user and team scope.
    public func loadAll(stackUserID: String? = nil, teamID: String? = nil) throws -> [MobilePairedMac] {
        try ensureReady()
        return try fetchAllMacs(stackUserID: stackUserID, teamID: teamID)
    }

    /// Load the active paired Mac in the optional Stack user and team scope.
    public func activeMac(stackUserID: String? = nil, teamID: String? = nil) throws -> MobilePairedMac? {
        try ensureReady()
        return try fetchAllMacs(activeOnly: true, stackUserID: stackUserID, teamID: teamID).first
    }

    /// Mark one paired Mac active within its explicit account/team owner scope.
    public func setActive(macDeviceID: String, stackUserID: String? = nil, teamID: String? = nil) throws {
        try ensureReady()
        let ownerKey = "\(stackUserID ?? "")\u{1F}\(teamID ?? "")"
        try transaction {
            try clearActiveMacs(stackUserID: stackUserID, teamID: teamID)
            try exec("UPDATE paired_macs SET is_active = 1 WHERE mac_device_id = ? AND owner_key = ?;",
                     binding: [.text(macDeviceID), .text(ownerKey)])
        }
    }

    /// Clear the active paired Mac in the optional Stack user and team scope.
    public func clearActive(stackUserID: String? = nil, teamID: String? = nil) throws {
        try ensureReady()
        try clearActiveMacs(stackUserID: stackUserID, teamID: teamID)
    }

    /// Persist user-facing customizations for one paired Mac.
    public func setCustomization(
        macDeviceID: String,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String? = nil,
        teamID: String? = nil,
        now: Date = Date()
    ) throws {
        try ensureReady()
        // Bump last_seen_at so the change is the freshest write for this record and
        // the LWW backup/restore propagates it to the user's other devices. Leaves
        // display_name / routes / is_active untouched (the Mac owns those).
        try exec("""
            UPDATE paired_macs
            SET custom_name = ?, custom_color = ?, custom_icon = ?, last_seen_at = ?
            WHERE mac_device_id = ? AND owner_key = ?;
        """, binding: [
            customName.map(BindValue.text) ?? .null,
            customColor.map(BindValue.text) ?? .null,
            customIcon.map(BindValue.text) ?? .null,
            .real(now.timeIntervalSince1970),
            .text(macDeviceID),
            .text("\(stackUserID ?? "")\u{1F}\(teamID ?? "")"),
        ])
    }

    /// Remove one paired Mac in a specific owner scope, or all matching legacy rows when unscoped.
    public func remove(macDeviceID: String, stackUserID: String? = nil, teamID: String? = nil) throws {
        try ensureReady()
        if stackUserID == nil && teamID == nil {
            try exec("DELETE FROM paired_macs WHERE mac_device_id = ?;",
                     binding: [.text(macDeviceID)])
        } else {
            try exec(
                "DELETE FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;",
                binding: [.text(macDeviceID), .text("\(stackUserID ?? "")\u{1F}\(teamID ?? "")")]
            )
        }
    }

    /// Remove every locally stored paired Mac and route.
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
        let ownerKey: String
        let displayName: String?
        let stackUserID: String?
        var teamID: String? = nil
        let createdAt: Date
        let lastSeenAt: Date
        let isActive: Bool
        var customName: String? = nil
        var customColor: String? = nil
        var customIcon: String? = nil
        var attachToken: String? = nil
        var attachTokenExpiresAt: Date? = nil
    }

    private func fetchMacRow(macDeviceID: String, ownerKey: String) throws -> MacRow? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT display_name, stack_user_id, created_at, last_seen_at, is_active, team_id,
                   attach_token, attach_token_expires_at
            FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: [.text(macDeviceID), .text(ownerKey)])
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
        let teamID = Self.readNullableText(statement, column: 5)
        let attachToken = Self.readNullableText(statement, column: 6)
        let attachTokenExpiresAt: Date?
        if sqlite3_column_type(statement, 7) == SQLITE_NULL {
            attachTokenExpiresAt = nil
        } else {
            attachTokenExpiresAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        }
        return MacRow(
            macDeviceID: macDeviceID,
            ownerKey: ownerKey,
            displayName: displayName,
            stackUserID: stackUserID,
            teamID: teamID,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            isActive: isActive,
            attachToken: attachToken,
            attachTokenExpiresAt: attachTokenExpiresAt
        )
    }

    private func upsertMacRow(
        macDeviceID: String,
        ownerKey: String,
        displayName: String?,
        stackUserID: String?,
        teamID: String?,
        attachToken: String?,
        attachTokenExpiresAt: Date?,
        createdAt: Date,
        lastSeenAt: Date,
        isActive: Bool
    ) throws {
        try exec("""
            INSERT INTO paired_macs (
                mac_device_id, owner_key, display_name, stack_user_id, team_id,
                attach_token, attach_token_expires_at, created_at, last_seen_at, is_active
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(mac_device_id, owner_key) DO UPDATE SET
                display_name = excluded.display_name,
                stack_user_id = excluded.stack_user_id,
                team_id = excluded.team_id,
                attach_token = COALESCE(excluded.attach_token, attach_token),
                attach_token_expires_at = CASE
                    WHEN excluded.attach_token IS NOT NULL THEN excluded.attach_token_expires_at
                    ELSE attach_token_expires_at
                END,
                last_seen_at = excluded.last_seen_at,
                is_active = excluded.is_active;
        """, binding: [
            .text(macDeviceID),
            .text(ownerKey),
            displayName.map(BindValue.text) ?? .null,
            stackUserID.map(BindValue.text) ?? .null,
            teamID.map(BindValue.text) ?? .null,
            attachToken.map(BindValue.text) ?? .null,
            attachTokenExpiresAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            .real(createdAt.timeIntervalSince1970),
            .real(lastSeenAt.timeIntervalSince1970),
            .int(isActive ? 1 : 0),
        ])
    }

    private func clearActiveMacs(stackUserID: String?, teamID: String?) throws {
        let stackBinding = stackUserID.map(BindValue.text) ?? .null
        if let teamID {
            // The visible team scope includes legacy NULL-team rows until their
            // next upsert claims them, so they must share the same active-row
            // invariant as explicit team rows.
            try exec("""
                UPDATE paired_macs SET is_active = 0
                WHERE stack_user_id IS ? AND (team_id IS ? OR team_id IS NULL);
            """, binding: [stackBinding, .text(teamID)])
        } else {
            try exec("""
                UPDATE paired_macs SET is_active = 0
                WHERE stack_user_id IS ? AND team_id IS NULL;
            """, binding: [stackBinding])
        }
    }

    private func moveMacRowScope(
        macDeviceID: String,
        fromOwnerKey: String,
        toOwnerKey: String,
        teamID: String?
    ) throws {
        try exec("""
            INSERT INTO paired_macs (
                mac_device_id, owner_key, display_name, stack_user_id, team_id,
                created_at, last_seen_at, is_active, custom_name, custom_color, custom_icon,
                attach_token, attach_token_expires_at
            )
            SELECT
                mac_device_id, ?, display_name, stack_user_id, ?, created_at,
                last_seen_at, is_active, custom_name, custom_color, custom_icon,
                attach_token, attach_token_expires_at
            FROM paired_macs
            WHERE mac_device_id = ? AND owner_key = ?;
        """, binding: [
            .text(toOwnerKey),
            teamID.map(BindValue.text) ?? .null,
            .text(macDeviceID),
            .text(fromOwnerKey),
        ])
        try exec("""
            UPDATE mac_routes
            SET owner_key = ?
            WHERE mac_device_id = ? AND owner_key = ?;
        """, binding: [
            .text(toOwnerKey),
            .text(macDeviceID),
            .text(fromOwnerKey),
        ])
        try exec("""
            DELETE FROM paired_macs
            WHERE mac_device_id = ? AND owner_key = ?;
        """, binding: [
            .text(macDeviceID),
            .text(fromOwnerKey),
        ])
    }

    private func fetchAllMacs(
        activeOnly: Bool = false, stackUserID: String? = nil, teamID: String? = nil
    ) throws -> [MobilePairedMac] {
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
        if let teamID {
            // Legacy-visibility: a NULL-team row (pre-v3 upgrade, or anonymous
            // pairing) is visible under EVERY team so an upgrade never hides an
            // existing host; it is stamped with the active team on the next upsert.
            clauses.append("(team_id IS ? OR team_id IS NULL)")
            bindings.append(.text(teamID))
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT mac_device_id, owner_key, display_name, stack_user_id, created_at, last_seen_at, is_active,
                   custom_name, custom_color, custom_icon, team_id, attach_token, attach_token_expires_at
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
            guard let ownerCString = sqlite3_column_text(statement, 1) else { continue }
            let ownerKey = String(cString: ownerCString)
            let displayName = Self.readNullableText(statement, column: 2)
            let storedStackUserID = Self.readNullableText(statement, column: 3)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let lastSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            let isActive = sqlite3_column_int(statement, 6) != 0
            let attachTokenExpiresAt: Date?
            if sqlite3_column_type(statement, 12) == SQLITE_NULL {
                attachTokenExpiresAt = nil
            } else {
                attachTokenExpiresAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
            }
            rows.append(MacRow(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                displayName: displayName,
                stackUserID: storedStackUserID,
                teamID: Self.readNullableText(statement, column: 10),
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                isActive: isActive,
                customName: Self.readNullableText(statement, column: 7),
                customColor: Self.readNullableText(statement, column: 8),
                customIcon: Self.readNullableText(statement, column: 9),
                attachToken: Self.readNullableText(statement, column: 11),
                attachTokenExpiresAt: attachTokenExpiresAt
            ))
        }

        return try rows.map { row in
            let routes = try fetchRoutes(macDeviceID: row.macDeviceID, ownerKey: row.ownerKey)
            return MobilePairedMac(
                macDeviceID: row.macDeviceID,
                displayName: row.displayName,
                routes: routes,
                attachToken: row.attachToken,
                attachTokenExpiresAt: row.attachTokenExpiresAt,
                createdAt: row.createdAt,
                lastSeenAt: row.lastSeenAt,
                isActive: row.isActive,
                stackUserID: row.stackUserID,
                teamID: row.teamID,
                customName: row.customName,
                customColor: row.customColor,
                customIcon: row.customIcon
            )
        }
    }

    private func fetchRoutes(macDeviceID: String, ownerKey: String) throws -> [CmxAttachRoute] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT endpoint_json
            FROM mac_routes
            WHERE mac_device_id = ? AND owner_key = ?
            ORDER BY priority ASC, id ASC;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: [.text(macDeviceID), .text(ownerKey)])

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
