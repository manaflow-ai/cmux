public import CMUXMobileCore
public import Foundation
import SQLite3
import os

let pairedMacStoreLog = Logger(subsystem: "com.cmuxterm.app", category: "PairedMacStore")

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
    nonisolated(unsafe) var db: OpaquePointer?

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

    /// v5: authenticated Mac app-instance identity. Additive and nullable so
    /// rows created by older builds keep the conservative sole-instance route
    /// policy until the next authenticated `mobile.host.status` response.
    private func migrateToV5() throws {
        let existing = try tableColumns("paired_macs")
        if !existing.contains("instance_tag") {
            try exec("ALTER TABLE paired_macs ADD COLUMN instance_tag TEXT;")
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
        instanceTag: String? = nil,
        markActive: Bool,
        stackUserID: String?,
        teamID: String? = nil,
        now: Date = Date()
    ) throws {
        _ = try upsertRecord(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now,
            restoredCustomizations: nil,
            onlyIfOlder: false
        )
    }

    /// Atomically restore only when the scoped row is absent or strictly older.
    @discardableResult
    public func upsertIfNewer(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        markActive: Bool,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        try upsertRecord(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: instanceTag,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now,
            restoredCustomizations: (customName, customColor, customIcon),
            onlyIfOlder: true
        )
    }

    /// Atomically write route authority only while the current scoped row is
    /// still authorized by `condition`.
    @discardableResult
    public func upsertRoutesIfAuthorized(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        condition: MobilePairedMacRouteWriteCondition,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date
    ) async throws -> Bool {
        try upsertRecord(
            macDeviceID: macDeviceID,
            displayName: displayName,
            routes: routes,
            instanceTag: nil,
            markActive: markActive,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now,
            restoredCustomizations: nil,
            onlyIfOlder: false,
            routeWriteCondition: condition
        )
    }

    private func upsertRecord(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        markActive: Bool?,
        stackUserID: String?,
        teamID: String?,
        now: Date,
        restoredCustomizations: (String?, String?, String?)?,
        onlyIfOlder: Bool,
        routeWriteCondition: MobilePairedMacRouteWriteCondition? = nil
    ) throws -> Bool {
        try ensureReady()
        var didWrite = false
        try transaction {
            let ownerKey = "\(stackUserID ?? "")\u{1F}\(teamID ?? "")"
            let existing = try fetchMacRow(macDeviceID: macDeviceID, ownerKey: ownerKey)
            let claimedLegacy: MacRow?
            if existing == nil,
               teamID != nil,
               let legacy = try fetchMacRow(
                    macDeviceID: macDeviceID,
                    ownerKey: "\(stackUserID ?? "")\u{1F}"
               ) {
                claimedLegacy = legacy
            } else {
                claimedLegacy = nil
            }
            let current = existing ?? claimedLegacy
            if onlyIfOlder, instanceTag == nil, current?.instanceTag != nil {
                // An authority-less backup cannot identify the process that
                // supplied its host tuple. Reject the whole tuple instead of
                // combining its routes or freshness with retained authority.
                return
            }
            if let routeWriteCondition {
                switch routeWriteCondition {
                case .matchingInstanceTag(let expectedInstanceTag):
                    guard let current, current.instanceTag == expectedInstanceTag else { return }
                case .unclaimed:
                    guard current?.instanceTag == nil else { return }
                }
            }
            if onlyIfOlder, let current, current.lastSeenAt >= now {
                return
            }
            let shouldMarkActive: Bool
            if routeWriteCondition != nil {
                shouldMarkActive = markActive ?? current?.isActive ?? false
            } else if onlyIfOlder, let current {
                // Preserve the target's live selection state. Restore computed
                // its flag before this transaction, while set/clearActive may
                // have changed it without changing lastSeenAt.
                shouldMarkActive = current.isActive
            } else if onlyIfOlder, markActive == true {
                // A missing backup-active row may claim selection only when no
                // live row became active after restore's initial snapshot.
                shouldMarkActive = try !hasOtherActiveMac(
                    than: macDeviceID, stackUserID: stackUserID, teamID: teamID
                )
            } else {
                shouldMarkActive = markActive ?? false
            }
            if shouldMarkActive {
                try clearActiveMacs(stackUserID: stackUserID, teamID: teamID)
            }
            if let claimedLegacy {
                try moveMacRowScope(
                    macDeviceID: macDeviceID,
                    fromOwnerKey: claimedLegacy.ownerKey,
                    toOwnerKey: ownerKey,
                    teamID: teamID
                )
            }
            let createdAt = existing?.createdAt ?? claimedLegacy?.createdAt ?? now
            let persistedInstanceTag = routeWriteCondition == nil
                ? instanceTag
                : current?.instanceTag
            try upsertMacRow(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                displayName: displayName,
                instanceTag: persistedInstanceTag,
                stackUserID: stackUserID,
                teamID: teamID,
                createdAt: createdAt,
                lastSeenAt: now,
                isActive: shouldMarkActive
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
            if let restoredCustomizations {
                try exec("""
                    UPDATE paired_macs
                    SET custom_name = ?, custom_color = ?, custom_icon = ?
                    WHERE mac_device_id = ? AND owner_key = ?;
                """, binding: [
                    restoredCustomizations.0.map(BindValue.text) ?? .null,
                    restoredCustomizations.1.map(BindValue.text) ?? .null,
                    restoredCustomizations.2.map(BindValue.text) ?? .null,
                    .text(macDeviceID),
                    .text(ownerKey),
                ])
            }
            didWrite = true
        }
        return didWrite
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

}
