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
    public static let currentSchemaVersion: Int32 = 8

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
                try migrateToV6()
                try migrateToV7()
                try migrateToV8()
                try setUserVersion(8)
            }
        case 1:
            try transaction {
                try migrateToV2()
                try migrateToV3()
                try migrateToV4()
                try migrateToV5()
                try migrateToV6()
                try migrateToV7()
                try migrateToV8()
                try setUserVersion(8)
            }
        case 2:
            try transaction {
                try migrateToV3()
                try migrateToV4()
                try migrateToV5()
                try migrateToV6()
                try migrateToV7()
                try migrateToV8()
                try setUserVersion(8)
            }
        case 3:
            try transaction {
                try migrateToV4()
                try migrateToV5()
                try migrateToV6()
                try migrateToV7()
                try migrateToV8()
                try setUserVersion(8)
            }
        case 4:
            try transaction {
                try migrateToV5()
                try migrateToV6()
                try migrateToV7()
                try migrateToV8()
                try setUserVersion(8)
            }
        case 5:
            try transaction {
                try migrateToV6()
                try migrateToV7()
                try migrateToV8()
                try setUserVersion(8)
            }
        case 6:
            try transaction {
                try migrateToV7()
                try migrateToV8()
                try setUserVersion(8)
            }
        case 7:
            try transaction {
                try migrateToV8()
                try setUserVersion(8)
            }
        case 8:
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

    /// v6: make the authenticated app-instance tag part of durable row identity.
    /// Stable, Nightly, and tagged development builds on one physical Mac share
    /// `mac_device_id`; folding the normalized tag into `owner_key` lets each
    /// process retain its own reconnect routes while preserving the existing
    /// account/team columns and query behavior.
    private func migrateToV6() throws {
        try exec("""
            CREATE TABLE paired_macs_v6 (
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
                instance_tag TEXT,
                PRIMARY KEY (mac_device_id, owner_key)
            );
        """)
        try exec("""
            INSERT INTO paired_macs_v6 (
                mac_device_id, owner_key, display_name, stack_user_id, team_id,
                created_at, last_seen_at, is_active, custom_name, custom_color,
                custom_icon, instance_tag
            )
            SELECT
                mac_device_id,
                IFNULL(stack_user_id, '') || char(31) || IFNULL(team_id, '')
                    || char(31) || IFNULL(instance_tag, ''),
                display_name, stack_user_id, team_id, created_at, last_seen_at,
                is_active, custom_name, custom_color, custom_icon, instance_tag
            FROM paired_macs;
        """)
        try exec("""
            CREATE TABLE mac_routes_v6 (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mac_device_id TEXT NOT NULL,
                owner_key TEXT NOT NULL,
                route_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                endpoint_json TEXT NOT NULL,
                priority INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (mac_device_id, owner_key)
                    REFERENCES paired_macs_v6(mac_device_id, owner_key)
                    ON DELETE CASCADE
            );
        """)
        try exec("""
            INSERT INTO mac_routes_v6 (
                mac_device_id, owner_key, route_id, kind, endpoint_json, priority
            )
            SELECT
                routes.mac_device_id,
                IFNULL(macs.stack_user_id, '') || char(31) || IFNULL(macs.team_id, '')
                    || char(31) || IFNULL(macs.instance_tag, ''),
                routes.route_id, routes.kind, routes.endpoint_json, routes.priority
            FROM mac_routes routes
            JOIN paired_macs macs
              ON macs.mac_device_id = routes.mac_device_id
             AND macs.owner_key = routes.owner_key;
        """)
        try exec("DROP TABLE mac_routes;")
        try exec("DROP TABLE paired_macs;")
        try exec("ALTER TABLE paired_macs_v6 RENAME TO paired_macs;")
        try exec("ALTER TABLE mac_routes_v6 RENAME TO mac_routes;")
        try exec("CREATE INDEX IF NOT EXISTS idx_macs_stack_user ON paired_macs(stack_user_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_macs_team ON paired_macs(stack_user_id, team_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_routes_device ON mac_routes(mac_device_id, owner_key);")
    }

    /// v8: preserve only the exact raw Tailscale destinations that this local
    /// installation used before Iroh shipped. The table is deliberately absent
    /// from account backup, so a new install, a second phone, or a restored row
    /// cannot acquire this bearer-carrying compatibility capability.
    ///
    /// Rows that already contain Iroh are excluded. Once Iroh is persisted,
    /// ``upsertRecord`` deletes any remaining grants and never recreates them.
    private func migrateToV8() throws {
        try exec("""
            CREATE TABLE legacy_tailscale_route_grants (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mac_device_id TEXT NOT NULL,
                owner_key TEXT NOT NULL,
                endpoint_json TEXT NOT NULL,
                UNIQUE (mac_device_id, owner_key, endpoint_json),
                FOREIGN KEY (mac_device_id, owner_key)
                    REFERENCES paired_macs(mac_device_id, owner_key)
                    ON DELETE CASCADE
            );
        """)
        try exec("""
            INSERT OR IGNORE INTO legacy_tailscale_route_grants (
                mac_device_id, owner_key, endpoint_json
            )
            SELECT routes.mac_device_id, routes.owner_key, routes.endpoint_json
            FROM mac_routes routes
            WHERE routes.kind = 'tailscale'
              AND EXISTS (
                SELECT 1 FROM paired_macs macs
                WHERE macs.mac_device_id = routes.mac_device_id
                  AND macs.owner_key = routes.owner_key
                  AND macs.stack_user_id IS NOT NULL
                  AND macs.stack_user_id <> ''
              )
              AND NOT EXISTS (
                SELECT 1 FROM mac_routes iroh
                WHERE iroh.mac_device_id = routes.mac_device_id
                  AND iroh.owner_key = routes.owner_key
                  AND iroh.kind = 'iroh'
              );
        """)
        try exec("""
            CREATE INDEX idx_legacy_tailscale_grants_device
            ON legacy_tailscale_route_grants(mac_device_id, owner_key);
        """)
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
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        var didWrite = false
        try transaction {
            let recordInstanceTag: String?
            switch routeWriteCondition {
            case .matchingInstanceTag(let expectedInstanceTag):
                recordInstanceTag = expectedInstanceTag
            case .unclaimed:
                recordInstanceTag = nil
            case nil:
                recordInstanceTag = instanceTag
            }
            let ownerKey = Self.ownerKey(
                stackUserID: stackUserID,
                teamID: teamID,
                instanceTag: recordInstanceTag
            )
            let existing = try fetchMacRow(macDeviceID: macDeviceID, ownerKey: ownerKey)
            let selectedUnclaimed = recordInstanceTag == nil ? nil : try fetchMacRow(
                macDeviceID: macDeviceID,
                ownerKey: Self.ownerKey(
                    stackUserID: stackUserID,
                    teamID: teamID,
                    instanceTag: nil
                )
            )
            let teamlessExact = existing == nil && teamID != nil ? try fetchMacRow(
                macDeviceID: macDeviceID,
                ownerKey: Self.ownerKey(
                    stackUserID: stackUserID,
                    teamID: nil,
                    instanceTag: recordInstanceTag
                )
            ) : nil
            let teamlessUnclaimed = existing == nil && selectedUnclaimed == nil
                && teamID != nil && recordInstanceTag != nil ? try fetchMacRow(
                    macDeviceID: macDeviceID,
                    ownerKey: Self.ownerKey(
                        stackUserID: stackUserID,
                        teamID: nil,
                        instanceTag: nil
                    )
                ) : nil
            let claimable = existing == nil
                ? (selectedUnclaimed ?? teamlessExact ?? teamlessUnclaimed)
                : nil
            let current = existing ?? claimable
            if routeWriteCondition == .unclaimed {
                let hasClaimedSibling = try fetchAllMacs(
                    stackUserID: stackUserID,
                    teamID: teamID
                ).contains {
                    $0.macDeviceID == macDeviceID && $0.instanceTag != nil
                }
                guard !hasClaimedSibling else { return }
            }
            if onlyIfOlder, instanceTag == nil {
                let hasClaimedSibling = try fetchAllMacs(
                    stackUserID: stackUserID,
                    teamID: teamID
                ).contains {
                    $0.macDeviceID == macDeviceID && $0.instanceTag != nil
                }
                guard !hasClaimedSibling else { return }
            }
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
                    thanOwnerKey: ownerKey,
                    macDeviceID: macDeviceID,
                    stackUserID: stackUserID,
                    teamID: teamID
                )
            } else {
                shouldMarkActive = markActive ?? false
            }
            if shouldMarkActive {
                try clearActiveMacs(stackUserID: stackUserID, teamID: teamID)
            }
            if let claimable {
                try moveMacRowScope(
                    macDeviceID: macDeviceID,
                    fromOwnerKey: claimable.ownerKey,
                    toOwnerKey: ownerKey,
                    teamID: teamID
                )
            }
            let existingRoutes: [CmxAttachRoute]
            if existing != nil || claimable != nil {
                existingRoutes = try fetchRoutes(
                    macDeviceID: macDeviceID,
                    ownerKey: ownerKey
                )
            } else {
                existingRoutes = []
            }
            let incomingHasIroh = routes.contains { $0.kind == .iroh }
            let pinnedIrohRoutes = existingRoutes.filter { $0.kind == .iroh }
            // Iroh capability is sticky for one paired Mac. Presence, backup, or
            // an older host build may temporarily publish only raw private-network
            // routes; replacing the stored Iroh identity in that case would allow
            // a later admission failure to downgrade into Stack-bearer RPC. A new
            // Iroh route replaces the old identity normally.
            let routesToPersist = incomingHasIroh || pinnedIrohRoutes.isEmpty
                ? routes
                : routes + pinnedIrohRoutes
            let createdAt = existing?.createdAt ?? claimable?.createdAt ?? now
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
            if routesToPersist.contains(where: { $0.kind == .iroh }) {
                try exec(
                    """
                    DELETE FROM legacy_tailscale_route_grants
                    WHERE mac_device_id = ? AND owner_key = ?;
                    """,
                    binding: [.text(macDeviceID), .text(ownerKey)]
                )
            }
            if existing != nil, let selectedUnclaimed,
               selectedUnclaimed.ownerKey != ownerKey {
                try exec(
                    "DELETE FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;",
                    binding: [.text(macDeviceID), .text(selectedUnclaimed.ownerKey)]
                )
            }
            try exec(
                "DELETE FROM mac_routes WHERE mac_device_id = ? AND owner_key = ?;",
                binding: [.text(macDeviceID), .text(ownerKey)]
            )
            for route in routesToPersist {
                guard let persistedRoute = route.disclosed(
                    for: .authenticated,
                    at: now
                ) else {
                    continue
                }
                let encoded = try Self.encodeRoute(persistedRoute)
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
    public func setActive(
        macDeviceID: String,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let instanceTag = try fetchAllMacs(
            stackUserID: stackUserID,
            teamID: teamID
        ).first { $0.macDeviceID == macDeviceID }?.instanceTag
        try setActive(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    /// Mark one tagged paired Mac active within its account/team owner scope.
    public func setActive(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let ownerKey = Self.ownerKey(
            stackUserID: stackUserID,
            teamID: teamID,
            instanceTag: instanceTag
        )
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
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let instanceTag = try fetchAllMacs(
            stackUserID: stackUserID,
            teamID: teamID
        ).first { $0.macDeviceID == macDeviceID }?.instanceTag
        try setCustomization(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            customName: customName,
            customColor: customColor,
            customIcon: customIcon,
            stackUserID: stackUserID,
            teamID: teamID,
            now: now
        )
    }

    /// Persist user-facing customizations for one tagged paired Mac.
    public func setCustomization(
        macDeviceID: String,
        instanceTag: String?,
        customName: String?,
        customColor: String?,
        customIcon: String?,
        stackUserID: String? = nil,
        teamID: String? = nil,
        now: Date = Date()
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
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
            .text(Self.ownerKey(
                stackUserID: stackUserID,
                teamID: teamID,
                instanceTag: instanceTag
            )),
        ])
    }

    /// Remove one paired Mac in a specific owner scope, or all matching legacy rows when unscoped.
    public func remove(
        macDeviceID: String,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) throws {
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        if stackUserID == nil && teamID == nil {
            try ensureReady()
            try exec("DELETE FROM paired_macs WHERE mac_device_id = ?;",
                     binding: [.text(macDeviceID)])
            return
        }
        try ensureReady()
        let instanceTag = try fetchAllMacs(
            stackUserID: stackUserID,
            teamID: teamID
        ).first { $0.macDeviceID == macDeviceID }?.instanceTag
        try remove(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID
        )
    }

    /// Remove one tagged paired Mac in a specific owner scope.
    public func remove(
        macDeviceID: String,
        instanceTag: String?,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) throws {
        try ensureReady()
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        try exec(
            "DELETE FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;",
            binding: [.text(macDeviceID), .text(Self.ownerKey(
                stackUserID: stackUserID,
                teamID: teamID,
                instanceTag: instanceTag
            ))]
        )
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

    private nonisolated static func ownerKey(
        stackUserID: String?,
        teamID: String?,
        instanceTag: String?
    ) -> String {
        "\(stackUserID ?? "")\u{1F}\(teamID ?? "")\u{1F}\(instanceTag ?? "")"
    }

}
