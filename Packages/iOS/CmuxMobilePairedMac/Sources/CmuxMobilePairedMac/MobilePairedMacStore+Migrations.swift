import CMUXMobileCore
import Foundation
import SQLite3
import os

// MobilePairedMacStore's schema: opening the SQLite connection and migrating it to
// `currentSchemaVersion`, once, on first access.
extension MobilePairedMacStore {
    // MARK: - Open + migrate

    /// Open the SQLite connection and set connection pragmas. `nonisolated`
    /// `static` so the actor's synchronous initializer can build the handle
    /// without hopping isolation. Opened with `SQLITE_OPEN_FULLMUTEX` so SQLite
    /// serializes access internally; the actor adds an outer serialization layer.
    /// Schema migration runs lazily on first store access via `ensureReady()`.
    nonisolated static func openConnection(path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
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

    /// Run schema migrations exactly once, on first store access (actor-isolated).
    func ensureReady() throws {
        guard !didMigrate else { return }
        try runMigrations()
        if let importingLegacyDatabaseURL {
            try importLegacyDatabase(at: importingLegacyDatabaseURL)
        }
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
                try migrateToV9()
                try migrateToV10()
                try migrateToV11()
                try setUserVersion(11)
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
                try migrateToV9()
                try migrateToV10()
                try migrateToV11()
                try setUserVersion(11)
            }
        case 2:
            try transaction {
                try migrateToV3()
                try migrateToV4()
                try migrateToV5()
                try migrateToV6()
                try migrateToV7()
                try migrateToV8()
                try migrateToV9()
                try migrateToV10()
                try migrateToV11()
                try setUserVersion(11)
            }
        case 3:
            try transaction {
                try migrateToV4()
                try migrateToV5()
                try migrateToV6()
                try migrateToV7()
                try migrateToV8()
                try migrateToV9()
                try migrateToV10()
                try migrateToV11()
                try setUserVersion(11)
            }
        case 4:
            try transaction {
                try migrateToV5()
                try migrateToV6()
                try migrateToV7()
                try migrateToV8()
                try migrateToV9()
                try migrateToV10()
                try migrateToV11()
                try setUserVersion(11)
            }
        case 5:
            try transaction {
                try migrateToV6()
                try migrateToV7()
                try migrateToV8()
                try migrateToV9()
                try migrateToV10()
                try migrateToV11()
                try setUserVersion(11)
            }
        case 6:
            try transaction {
                try migrateToV7()
                try migrateToV8()
                try migrateToV9()
                try migrateToV10()
                try migrateToV11()
                try setUserVersion(11)
            }
        case 7:
            try transaction {
                try migrateToV8()
                try migrateToV9()
                try migrateToV10()
                try migrateToV11()
                try setUserVersion(11)
            }
        case 8:
            try transaction {
                try migrateToV9()
                try migrateToV10()
                try migrateToV11()
                try setUserVersion(11)
            }
        case 9:
            try transaction {
                try migrateToV10()
                try migrateToV11()
                try setUserVersion(11)
            }
        case 10:
            try transaction {
                try migrateToV11()
                try setUserVersion(11)
            }
        case 11:
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
        if version < 12 {
            try transaction {
                try migrateToV12()
                try setUserVersion(12)
            }
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

    /// v9: record where each Tailscale compatibility grant came from. The v8
    /// migration rows keep the `'migration'` origin and its lifecycle (deleted
    /// forever once Iroh is persisted). `'user'` rows are created when the user
    /// explicitly enters a Tailscale pairing code from their Mac and survive
    /// Iroh persistence, because the user chose Tailscale on purpose and may
    /// keep dialing it while the preference says so.
    private func migrateToV9() throws {
        let columns = try tableColumns("legacy_tailscale_route_grants")
        guard !columns.contains("origin") else { return }
        try exec("""
            ALTER TABLE legacy_tailscale_route_grants
            ADD COLUMN origin TEXT NOT NULL DEFAULT 'migration';
        """)
    }

    /// v10: this iPhone's per-Computer connection method ("iroh" or
    /// "tailscale"). Additive and device-local: the column never rides the
    /// account backup, and `NULL` means "use the app's default method".
    private func migrateToV10() throws {
        let columns = try tableColumns("paired_macs")
        guard !columns.contains("connection_method") else { return }
        try exec("ALTER TABLE paired_macs ADD COLUMN connection_method TEXT;")
    }

    /// v11: this iPhone's per-Computer Direct-method dial candidates (JSON
    /// array of {"address","port"?,"enabled"}). Additive and device-local,
    /// like `connection_method`.
    private func migrateToV11() throws {
        let columns = try tableColumns("paired_macs")
        guard !columns.contains("direct_addresses") else { return }
        try exec("ALTER TABLE paired_macs ADD COLUMN direct_addresses TEXT;")
    }

    /// v12: device-local route tombstones. A paired Mac can keep advertising a
    /// route after the user removes it on this iPhone, so route refreshes must
    /// remember the endpoint suppression independently of the host snapshot.
    /// The table is intentionally not part of the backup record and is removed
    /// with its paired-Mac row on forget/re-pair.
    private func migrateToV12() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS mac_route_removals (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mac_device_id TEXT NOT NULL,
                owner_key TEXT NOT NULL,
                kind TEXT NOT NULL,
                endpoint_json TEXT NOT NULL,
                UNIQUE (mac_device_id, owner_key, kind, endpoint_json),
                FOREIGN KEY (mac_device_id, owner_key)
                    REFERENCES paired_macs(mac_device_id, owner_key)
                    ON DELETE CASCADE
            );
        """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_route_removals_device
            ON mac_route_removals(mac_device_id, owner_key);
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
}
