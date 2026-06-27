import SQLite3

extension MobilePairedMacStore {
    /// Run schema migrations exactly once, on first store access (actor-isolated).
    func ensureReady() throws {
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
            // additive by contract - older builds keep reading the columns and
            // tables they already know (see
            // plans/feat-ios-paired-mac-backup/DESIGN.md section 4 and the same
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
    /// (some columns added, `user_version` still 1) - re-running here just adds
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
        let statement = try prepareStatement("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
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

    private func userVersion() throws -> Int32 {
        let statement = try prepareStatement("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
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
