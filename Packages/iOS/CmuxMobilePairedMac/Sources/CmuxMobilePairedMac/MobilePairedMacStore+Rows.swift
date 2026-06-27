import CMUXMobileCore
import Foundation
import SQLite3

extension MobilePairedMacStore {
    func fetchMacRow(macDeviceID: String, ownerKey: String) throws -> MobilePairedMacStoreMacRow? {
        let sql = """
            SELECT display_name, stack_user_id, created_at, last_seen_at, is_active, team_id,
                   attach_token_expires_at, attach_token_workspace_id, attach_token_terminal_id
            FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;
        """
        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement: statement, parameters: [.text(macDeviceID), .text(ownerKey)])
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
        let displayName = readNullableText(statement, column: 0)
        let stackUserID = readNullableText(statement, column: 1)
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        let lastSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        let isActive = sqlite3_column_int(statement, 4) != 0
        let teamID = readNullableText(statement, column: 5)
        let attachTokenExpiresAt: Date?
        if sqlite3_column_type(statement, 6) == SQLITE_NULL {
            attachTokenExpiresAt = nil
        } else {
            attachTokenExpiresAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        }
        return MobilePairedMacStoreMacRow(
            macDeviceID: macDeviceID,
            ownerKey: ownerKey,
            displayName: displayName,
            stackUserID: stackUserID,
            teamID: teamID,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            isActive: isActive,
            attachTokenExpiresAt: attachTokenExpiresAt,
            attachTokenWorkspaceID: readNullableText(statement, column: 7),
            attachTokenTerminalID: readNullableText(statement, column: 8)
        )
    }

    func upsertMacRow(
        macDeviceID: String,
        ownerKey: String,
        displayName: String?,
        stackUserID: String?,
        teamID: String?,
        attachTokenChanged: Bool,
        attachTokenExpiresAt: Date?,
        attachTokenWorkspaceID: String?,
        attachTokenTerminalID: String?,
        createdAt: Date,
        lastSeenAt: Date,
        isActive: Bool
    ) throws {
        try exec("""
            INSERT INTO paired_macs (
                mac_device_id, owner_key, display_name, stack_user_id, team_id,
                attach_token, attach_token_expires_at, attach_token_workspace_id, attach_token_terminal_id,
                created_at, last_seen_at, is_active
            )
            VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(mac_device_id, owner_key) DO UPDATE SET
                display_name = excluded.display_name,
                stack_user_id = excluded.stack_user_id,
                team_id = excluded.team_id,
                attach_token = NULL,
                attach_token_expires_at = CASE
                    WHEN ? = 1 THEN excluded.attach_token_expires_at
                    ELSE attach_token_expires_at
                END,
                attach_token_workspace_id = CASE
                    WHEN ? = 1 THEN excluded.attach_token_workspace_id
                    ELSE attach_token_workspace_id
                END,
                attach_token_terminal_id = CASE
                    WHEN ? = 1 THEN excluded.attach_token_terminal_id
                    ELSE attach_token_terminal_id
                END,
                last_seen_at = excluded.last_seen_at,
                is_active = excluded.is_active;
        """, binding: [
            .text(macDeviceID),
            .text(ownerKey),
            displayName.map(BindValue.text) ?? .null,
            stackUserID.map(BindValue.text) ?? .null,
            teamID.map(BindValue.text) ?? .null,
            attachTokenExpiresAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            attachTokenWorkspaceID.map(BindValue.text) ?? .null,
            attachTokenTerminalID.map(BindValue.text) ?? .null,
            .real(createdAt.timeIntervalSince1970),
            .real(lastSeenAt.timeIntervalSince1970),
            .int(isActive ? 1 : 0),
            .int(attachTokenChanged ? 1 : 0),
            .int(attachTokenChanged ? 1 : 0),
            .int(attachTokenChanged ? 1 : 0),
        ])
    }

    func clearActiveMacs(stackUserID: String?, teamID: String?) throws {
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

    func moveMacRowScope(
        macDeviceID: String,
        fromOwnerKey: String,
        toOwnerKey: String,
        teamID: String?
    ) throws {
        try exec("""
            INSERT INTO paired_macs (
                mac_device_id, owner_key, display_name, stack_user_id, team_id,
                created_at, last_seen_at, is_active, custom_name, custom_color, custom_icon,
                attach_token, attach_token_expires_at, attach_token_workspace_id, attach_token_terminal_id
            )
            SELECT
                mac_device_id, ?, display_name, stack_user_id, ?, created_at,
                last_seen_at, is_active, custom_name, custom_color, custom_icon,
                NULL, attach_token_expires_at, attach_token_workspace_id, attach_token_terminal_id
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

    func replaceRoutes(macDeviceID: String, ownerKey: String, routes: [CmxAttachRoute]) throws {
        try exec(
            "DELETE FROM mac_routes WHERE mac_device_id = ? AND owner_key = ?;",
            binding: [.text(macDeviceID), .text(ownerKey)]
        )
        for route in routes {
            let encoded = try encodeRoute(route)
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

    func fetchAllMacs(
        activeOnly: Bool = false, stackUserID: String? = nil, teamID: String? = nil
    ) async throws -> [MobilePairedMac] {
        let rows = try fetchAllMacRows(activeOnly: activeOnly, stackUserID: stackUserID, teamID: teamID)
        guard !rows.isEmpty else { return [] }

        let routesByKey = try fetchRoutesForMacRows(
            activeOnly: activeOnly,
            stackUserID: stackUserID,
            teamID: teamID
        )
        var macs: [MobilePairedMac] = []
        macs.reserveCapacity(rows.count)
        for row in rows {
            let key = MobilePairedMacStoreRouteKey(macDeviceID: row.macDeviceID, ownerKey: row.ownerKey)
            macs.append(MobilePairedMac(
                macDeviceID: row.macDeviceID,
                displayName: row.displayName,
                routes: routesByKey[key] ?? [],
                attachToken: await attachTokenSecret(for: row),
                attachTokenExpiresAt: row.attachTokenExpiresAt,
                attachTokenWorkspaceID: row.attachTokenWorkspaceID,
                attachTokenTerminalID: row.attachTokenTerminalID,
                createdAt: row.createdAt,
                lastSeenAt: row.lastSeenAt,
                isActive: row.isActive,
                stackUserID: row.stackUserID,
                teamID: row.teamID,
                customName: row.customName,
                customColor: row.customColor,
                customIcon: row.customIcon
            ))
        }
        return macs
    }

    func fetchAllMacRows(
        activeOnly: Bool = false, stackUserID: String? = nil, teamID: String? = nil
    ) throws -> [MobilePairedMacStoreMacRow] {
        let filter = macRowFilter(activeOnly: activeOnly, stackUserID: stackUserID, teamID: teamID)
        let sql = """
            SELECT mac_device_id, owner_key, display_name, stack_user_id, created_at, last_seen_at, is_active,
                   custom_name, custom_color, custom_icon, team_id, attach_token_expires_at,
                   attach_token_workspace_id, attach_token_terminal_id
            FROM paired_macs
            \(filter.whereClause)
            ORDER BY last_seen_at DESC;
        """
        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement: statement, parameters: filter.bindings)
        var rows: [MobilePairedMacStoreMacRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let cString = sqlite3_column_text(statement, 0) else {
                step = sqlite3_step(statement)
                continue
            }
            let macDeviceID = String(cString: cString)
            guard let ownerCString = sqlite3_column_text(statement, 1) else {
                step = sqlite3_step(statement)
                continue
            }
            let ownerKey = String(cString: ownerCString)
            let displayName = readNullableText(statement, column: 2)
            let storedStackUserID = readNullableText(statement, column: 3)
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let lastSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
            let isActive = sqlite3_column_int(statement, 6) != 0
            let attachTokenExpiresAt: Date?
            if sqlite3_column_type(statement, 11) == SQLITE_NULL {
                attachTokenExpiresAt = nil
            } else {
                attachTokenExpiresAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 11))
            }
            rows.append(MobilePairedMacStoreMacRow(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                displayName: displayName,
                stackUserID: storedStackUserID,
                teamID: readNullableText(statement, column: 10),
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                isActive: isActive,
                customName: readNullableText(statement, column: 7),
                customColor: readNullableText(statement, column: 8),
                customIcon: readNullableText(statement, column: 9),
                attachTokenExpiresAt: attachTokenExpiresAt,
                attachTokenWorkspaceID: readNullableText(statement, column: 12),
                attachTokenTerminalID: readNullableText(statement, column: 13)
            ))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
        return rows
    }

    func fetchMacRowsForRemoval(
        macDeviceID: String,
        stackUserID: String?,
        teamID: String?
    ) throws -> [MobilePairedMacStoreMacRow] {
        if stackUserID == nil && teamID == nil {
            return try fetchAllMacRows().filter { $0.macDeviceID == macDeviceID }
        }
        let ownerKey = "\(stackUserID ?? "")\u{1F}\(teamID ?? "")"
        return try fetchMacRow(macDeviceID: macDeviceID, ownerKey: ownerKey).map { [$0] } ?? []
    }

    private func macRowFilter(
        activeOnly: Bool,
        stackUserID: String?,
        teamID: String?,
        columnPrefix: String = ""
    ) -> (whereClause: String, bindings: [BindValue]) {
        var clauses: [String] = []
        var bindings: [BindValue] = []
        if activeOnly {
            clauses.append("\(columnPrefix)is_active = 1")
        }
        if let stackUserID {
            clauses.append("\(columnPrefix)stack_user_id IS ?")
            bindings.append(.text(stackUserID))
        }
        if let teamID {
            // Legacy-visibility: a NULL-team row (pre-v3 upgrade, or anonymous
            // pairing) is visible under EVERY team so an upgrade never hides an
            // existing host; it is stamped with the active team on the next upsert.
            clauses.append("(\(columnPrefix)team_id IS ? OR \(columnPrefix)team_id IS NULL)")
            bindings.append(.text(teamID))
        }
        let whereClause = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return (whereClause, bindings)
    }

    private func fetchRoutesForMacRows(
        activeOnly: Bool,
        stackUserID: String?,
        teamID: String?
    ) throws -> [MobilePairedMacStoreRouteKey: [CmxAttachRoute]] {
        let filter = macRowFilter(
            activeOnly: activeOnly,
            stackUserID: stackUserID,
            teamID: teamID,
            columnPrefix: "p."
        )
        let sql = """
            SELECT r.mac_device_id, r.owner_key, r.endpoint_json
            FROM mac_routes r
            INNER JOIN paired_macs p
                ON p.mac_device_id = r.mac_device_id
               AND p.owner_key = r.owner_key
            \(filter.whereClause)
            ORDER BY p.last_seen_at DESC, r.mac_device_id ASC, r.owner_key ASC, r.priority ASC, r.id ASC;
        """
        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement: statement, parameters: filter.bindings)

        var routesByKey: [MobilePairedMacStoreRouteKey: [CmxAttachRoute]] = [:]
        let decoder = JSONDecoder()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let macCString = sqlite3_column_text(statement, 0),
                  let ownerCString = sqlite3_column_text(statement, 1),
                  let routeCString = sqlite3_column_text(statement, 2) else {
                step = sqlite3_step(statement)
                continue
            }
            let key = MobilePairedMacStoreRouteKey(
                macDeviceID: String(cString: macCString),
                ownerKey: String(cString: ownerCString)
            )
            let json = String(cString: routeCString)
            guard let data = json.data(using: .utf8),
                  let route = try? decoder.decode(CmxAttachRoute.self, from: data) else {
                pairedMacStoreLog.warning("dropping unparsable route row")
                step = sqlite3_step(statement)
                continue
            }
            routesByKey[key, default: []].append(route)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
        return routesByKey
    }

    func encodeRoute(_ route: CmxAttachRoute) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(route)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MobilePairedMacStoreError.decodeFailed
        }
        return string
    }

    private func readNullableText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }
}
