import CMUXMobileCore
import Foundation
import SQLite3

extension MobilePairedMacStore {
    /// Imports local reconnect metadata once, keeping both databases' ownership
    /// keys intact. A completed import never replays after a user forgets a Mac.
    func importLegacyDatabase(at sourceURL: URL) throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }
        try exec("""
            CREATE TABLE IF NOT EXISTS paired_mac_store_imports (
                source TEXT PRIMARY KEY NOT NULL
            );
            """)
        var marker: OpaquePointer?
        let markerRC = sqlite3_prepare_v2(db,
            "SELECT 1 FROM paired_mac_store_imports WHERE source = 'legacy-local-v1';",
            -1, &marker, nil)
        guard markerRC == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(markerRC, lastErrorMessage())
        }
        let imported = sqlite3_step(marker) == SQLITE_ROW
        sqlite3_finalize(marker)
        guard !imported else { return }

        var source = URLComponents(url: sourceURL, resolvingAgainstBaseURL: true)
        source?.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let readOnlyURL = source?.string else {
            throw MobilePairedMacStoreError.decodeFailed
        }
        try exec("ATTACH DATABASE ? AS legacy_saved_macs;", binding: [.text(readOnlyURL)])
        defer { try? exec("DETACH DATABASE legacy_saved_macs;") }

        let columns = try legacyImportColumns(table: "paired_macs")
        guard columns.contains("mac_device_id") else {
            throw MobilePairedMacStoreError.decodeFailed
        }
        let optionalColumns = ["team_id", "instance_tag", "custom_name", "custom_color", "custom_icon",
                               "connection_method", "direct_addresses"]
        let expressions = optionalColumns.map { columns.contains($0) ? "old.\($0)" : "NULL" }
        let team = columns.contains("team_id") ? "old.team_id" : "NULL"
        let tag = columns.contains("instance_tag") ? "old.instance_tag" : "NULL"
        let owner = columns.contains("owner_key") ? "old.owner_key"
            : "IFNULL(old.stack_user_id, '') || char(31) || IFNULL(\(team), '') || char(31) || IFNULL(\(tag), '')"

        // A deferred transaction reads the read-only source snapshot before
        // writing the destination. BEGIN IMMEDIATE would also request a write
        // lock on the attached source, which must stay read-only.
        try transaction(immediate: false) {
            try exec("""
                CREATE TEMP TABLE legacy_mac_import_rows AS
                SELECT old.mac_device_id, \(owner) AS owner_key, old.display_name,
                       old.stack_user_id, old.created_at, old.last_seen_at, old.is_active,
                       \(zip(expressions, optionalColumns).map { expression, column in
                           "\(expression) AS \(column)"
                       }.joined(separator: ", "))
                FROM legacy_saved_macs.paired_macs old
                WHERE NOT EXISTS (
                    SELECT 1 FROM main.paired_macs current
                    WHERE current.mac_device_id = old.mac_device_id AND current.owner_key = \(owner)
                );
                """)
            defer { try? exec("DROP TABLE IF EXISTS temp.legacy_mac_import_rows;") }
            try exec("""
                INSERT INTO main.paired_macs (
                    mac_device_id, owner_key, display_name, stack_user_id,
                    created_at, last_seen_at, is_active, \(optionalColumns.joined(separator: ", "))
                )
                SELECT old.mac_device_id, old.owner_key, old.display_name, old.stack_user_id,
                       old.created_at, old.last_seen_at,
                       CASE WHEN EXISTS (
                           SELECT 1 FROM main.paired_macs current
                           WHERE current.stack_user_id IS old.stack_user_id
                             AND current.team_id IS old.team_id AND current.is_active = 1
                       ) THEN 0 ELSE old.is_active END,
                       \(optionalColumns.map { "old.\($0)" }.joined(separator: ", "))
                FROM temp.legacy_mac_import_rows old;
                """)
            // Keep this update explicit rather than relying on a positional
            // projection: older stores may lack any of these nullable columns.
            for column in ["custom_name", "custom_color", "custom_icon",
                           "connection_method", "direct_addresses"] where columns.contains(column) {
                try exec("""
                    UPDATE main.paired_macs
                    SET \(column) = (
                        SELECT old.\(column) FROM legacy_saved_macs.paired_macs old
                        WHERE old.mac_device_id = main.paired_macs.mac_device_id
                          AND \(owner) = main.paired_macs.owner_key
                    )
                    WHERE EXISTS (
                        SELECT 1 FROM temp.legacy_mac_import_rows imported
                        WHERE imported.mac_device_id = main.paired_macs.mac_device_id
                          AND imported.owner_key = main.paired_macs.owner_key
                    );
                    """)
            }
            try importLegacyRoutes()
            if !(try legacyImportColumns(table: "mac_route_removals")).isEmpty {
                try exec("""
                    INSERT OR IGNORE INTO main.mac_route_removals
                        (mac_device_id, owner_key, kind, endpoint_json)
                    SELECT removed.mac_device_id, removed.owner_key, removed.kind, removed.endpoint_json
                    FROM legacy_saved_macs.mac_route_removals removed
                    JOIN temp.legacy_mac_import_rows imported
                      ON imported.mac_device_id = removed.mac_device_id
                     AND imported.owner_key = removed.owner_key;
                    """)
            }
            // No legacy credential, trust-grant, or admission state is imported.
            try exec("INSERT INTO paired_mac_store_imports (source) VALUES ('legacy-local-v1');")
        }
    }

    private func importLegacyRoutes() throws {
        let columns = try legacyImportColumns(table: "mac_routes")
        // Before owner keys existed, routes were keyed only by physical device;
        // copying them could assign one user's route to another user's row.
        // Preserve the saved Mac metadata and let a fresh authenticated host
        // update routes instead.
        guard columns.contains("owner_key") else { return }
        let ownerMatch = "AND routes.owner_key = imported.owner_key"
        let sql = """
            SELECT imported.mac_device_id, imported.owner_key, routes.endpoint_json
            FROM legacy_saved_macs.mac_routes routes
            JOIN temp.legacy_mac_import_rows imported ON imported.mac_device_id = routes.mac_device_id
            \(ownerMatch)
            ORDER BY routes.id;
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        let decoder = JSONDecoder()
        let now = Date()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
            }
            guard let device = Self.readNullableText(statement, column: 0),
                  let owner = Self.readNullableText(statement, column: 1),
                  let json = Self.readNullableText(statement, column: 2),
                  let data = json.data(using: .utf8),
                  let decoded = try? decoder.decode(CmxAttachRoute.self, from: data),
                  let route = decoded.disclosed(for: .authenticated, at: now) else { continue }
            try exec("""
                INSERT INTO main.mac_routes (mac_device_id, owner_key, route_id, kind, endpoint_json, priority)
                VALUES (?, ?, ?, ?, ?, ?);
                """, binding: [.text(device), .text(owner), .text(route.id), .text(route.kind.rawValue),
                                .text(try Self.encodeRoute(route)), .int(Int64(route.priority))])
        }
    }

    private func legacyImportColumns(table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, "PRAGMA legacy_saved_macs.table_info(\(table));", -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        var columns: Set<String> = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return columns }
            guard step == SQLITE_ROW else {
                throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
            }
            if let column = Self.readNullableText(statement, column: 1) { columns.insert(column) }
        }
    }
}
