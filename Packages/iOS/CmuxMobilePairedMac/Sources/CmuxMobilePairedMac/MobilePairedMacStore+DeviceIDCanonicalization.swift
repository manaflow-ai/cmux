import CMUXMobileCore
import Foundation
import SQLite3

extension MobilePairedMacStore {
    /// v7: canonicalize UUID device IDs and collapse case-only duplicates within
    /// each existing account/team/instance owner scope.
    ///
    /// A duplicate group's freshest row owns route authority and mutable metadata.
    /// Selection is preserved if any spelling was active, while creation and
    /// freshness retain the group's minimum and maximum timestamps respectively.
    func migrateToV7() throws {
        let rows = try fetchMacRowsForDeviceIDCanonicalization()
        try exec("""
            CREATE TABLE paired_macs_v7 (
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
            CREATE TABLE mac_routes_v7 (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                mac_device_id TEXT NOT NULL,
                owner_key TEXT NOT NULL,
                route_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                endpoint_json TEXT NOT NULL,
                priority INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (mac_device_id, owner_key)
                    REFERENCES paired_macs_v7(mac_device_id, owner_key)
                    ON DELETE CASCADE
            );
        """)

        for ownerRows in Dictionary(grouping: rows, by: \.ownerKey).values {
            let canonicalGroups = Dictionary(grouping: ownerRows) {
                cmxCanonicalDeviceID($0.macDeviceID)
            }
            for (canonicalDeviceID, duplicateRows) in canonicalGroups {
                guard let authoritative = authoritativeRow(
                    in: duplicateRows,
                    canonicalDeviceID: canonicalDeviceID
                ) else { continue }
                let createdAt = duplicateRows.map(\.createdAt).min() ?? authoritative.createdAt
                let lastSeenAt = duplicateRows.map(\.lastSeenAt).max() ?? authoritative.lastSeenAt
                let isActive = duplicateRows.contains(where: \.isActive)
                try exec("""
                    INSERT INTO paired_macs_v7 (
                        mac_device_id, owner_key, display_name, stack_user_id, team_id,
                        created_at, last_seen_at, is_active, custom_name, custom_color,
                        custom_icon, instance_tag
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, binding: [
                    .text(canonicalDeviceID),
                    .text(authoritative.ownerKey),
                    authoritative.displayName.map(BindValue.text) ?? .null,
                    authoritative.stackUserID.map(BindValue.text) ?? .null,
                    authoritative.teamID.map(BindValue.text) ?? .null,
                    .real(createdAt.timeIntervalSince1970),
                    .real(lastSeenAt.timeIntervalSince1970),
                    .int(isActive ? 1 : 0),
                    authoritative.customName.map(BindValue.text) ?? .null,
                    authoritative.customColor.map(BindValue.text) ?? .null,
                    authoritative.customIcon.map(BindValue.text) ?? .null,
                    authoritative.instanceTag.map(BindValue.text) ?? .null,
                ])
                try exec("""
                    INSERT INTO mac_routes_v7 (
                        mac_device_id, owner_key, route_id, kind, endpoint_json, priority
                    )
                    SELECT ?, owner_key, route_id, kind, endpoint_json, priority
                    FROM mac_routes
                    WHERE mac_device_id = ? AND owner_key = ?
                    ORDER BY id ASC;
                """, binding: [
                    .text(canonicalDeviceID),
                    .text(authoritative.macDeviceID),
                    .text(authoritative.ownerKey),
                ])
            }
        }

        try exec("DROP TABLE mac_routes;")
        try exec("DROP TABLE paired_macs;")
        try exec("ALTER TABLE paired_macs_v7 RENAME TO paired_macs;")
        try exec("ALTER TABLE mac_routes_v7 RENAME TO mac_routes;")
        try exec("CREATE INDEX IF NOT EXISTS idx_macs_stack_user ON paired_macs(stack_user_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_macs_team ON paired_macs(stack_user_id, team_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_routes_device ON mac_routes(mac_device_id, owner_key);")
    }

    private func fetchMacRowsForDeviceIDCanonicalization() throws -> [MacRow] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT mac_device_id, owner_key, display_name, stack_user_id, team_id,
                   created_at, last_seen_at, is_active, custom_name, custom_color,
                   custom_icon, instance_tag
            FROM paired_macs;
        """
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(result, lastErrorMessage())
        }

        var rows: [MacRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let deviceID = Self.readNullableText(statement, column: 0),
                  let ownerKey = Self.readNullableText(statement, column: 1) else {
                continue
            }
            rows.append(MacRow(
                macDeviceID: deviceID,
                ownerKey: ownerKey,
                displayName: Self.readNullableText(statement, column: 2),
                instanceTag: Self.readNullableText(statement, column: 11),
                stackUserID: Self.readNullableText(statement, column: 3),
                teamID: Self.readNullableText(statement, column: 4),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                isActive: sqlite3_column_int(statement, 7) != 0,
                customName: Self.readNullableText(statement, column: 8),
                customColor: Self.readNullableText(statement, column: 9),
                customIcon: Self.readNullableText(statement, column: 10)
            ))
        }
        return rows
    }

    private func authoritativeRow(
        in rows: [MacRow],
        canonicalDeviceID: String
    ) -> MacRow? {
        guard let first = rows.first else { return nil }
        return rows.dropFirst().reduce(first) { selected, candidate in
            guard candidate.lastSeenAt == selected.lastSeenAt else {
                return candidate.lastSeenAt > selected.lastSeenAt ? candidate : selected
            }
            let candidateIsCanonical = candidate.macDeviceID == canonicalDeviceID
            let selectedIsCanonical = selected.macDeviceID == canonicalDeviceID
            if candidateIsCanonical != selectedIsCanonical {
                return candidateIsCanonical ? candidate : selected
            }
            return candidate.macDeviceID < selected.macDeviceID ? candidate : selected
        }
    }
}
