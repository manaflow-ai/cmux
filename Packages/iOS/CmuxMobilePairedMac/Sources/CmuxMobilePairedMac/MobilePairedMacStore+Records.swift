import CMUXMobileCore
import Foundation
import SQLite3
import os

extension MobilePairedMacStore {
    struct MacRow {
        let macDeviceID: String
        let ownerKey: String
        let displayName: String?
        let instanceTag: String?
        let stackUserID: String?
        var teamID: String? = nil
        let createdAt: Date
        let lastSeenAt: Date
        let isActive: Bool
        var customName: String? = nil
        var customColor: String? = nil
        var customIcon: String? = nil
    }

    func fetchMacRow(macDeviceID: String, ownerKey: String) throws -> MacRow? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT display_name, stack_user_id, created_at, last_seen_at, is_active, team_id, instance_tag
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
        let instanceTag = Self.readNullableText(statement, column: 6)
        return MacRow(
            macDeviceID: macDeviceID,
            ownerKey: ownerKey,
            displayName: displayName,
            instanceTag: instanceTag,
            stackUserID: stackUserID,
            teamID: teamID,
            createdAt: createdAt,
            lastSeenAt: lastSeenAt,
            isActive: isActive
        )
    }

    func upsertMacRow(
        macDeviceID: String,
        ownerKey: String,
        displayName: String?,
        instanceTag: String?,
        stackUserID: String?,
        teamID: String?,
        createdAt: Date,
        lastSeenAt: Date,
        isActive: Bool
    ) throws {
        try exec("""
            INSERT INTO paired_macs (
                mac_device_id, owner_key, display_name, instance_tag, stack_user_id,
                team_id, created_at, last_seen_at, is_active
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(mac_device_id, owner_key) DO UPDATE SET
                display_name = excluded.display_name,
                instance_tag = excluded.instance_tag,
                stack_user_id = excluded.stack_user_id,
                team_id = excluded.team_id,
                last_seen_at = excluded.last_seen_at,
                is_active = excluded.is_active;
        """, binding: [
            .text(macDeviceID),
            .text(ownerKey),
            displayName.map(BindValue.text) ?? .null,
            instanceTag.map(BindValue.text) ?? .null,
            stackUserID.map(BindValue.text) ?? .null,
            teamID.map(BindValue.text) ?? .null,
            .real(createdAt.timeIntervalSince1970),
            .real(lastSeenAt.timeIntervalSince1970),
            .int(isActive ? 1 : 0),
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

    func hasOtherActiveMac(
        than macDeviceID: String,
        stackUserID: String?,
        teamID: String?
    ) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT 1 FROM paired_macs WHERE is_active = 1 AND mac_device_id <> ?
              AND stack_user_id IS ? AND ((? IS NULL AND team_id IS NULL)
                OR (? IS NOT NULL AND (team_id IS ? OR team_id IS NULL))) LIMIT 1;
        """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        let team = teamID.map(BindValue.text) ?? .null
        try bind(statement: statement, parameters: [
            .text(macDeviceID), stackUserID.map(BindValue.text) ?? .null,
            team, team, team,
        ])
        return sqlite3_step(statement) == SQLITE_ROW
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
                created_at, last_seen_at, is_active, custom_name, custom_color, custom_icon, instance_tag
            )
            SELECT
                mac_device_id, ?, display_name, stack_user_id, ?, created_at,
                last_seen_at, is_active, custom_name, custom_color, custom_icon, instance_tag
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

    func fetchAllMacs(
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
                   custom_name, custom_color, custom_icon, team_id, instance_tag
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
            rows.append(MacRow(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                displayName: displayName,
                instanceTag: Self.readNullableText(statement, column: 11),
                stackUserID: storedStackUserID,
                teamID: Self.readNullableText(statement, column: 10),
                createdAt: createdAt,
                lastSeenAt: lastSeenAt,
                isActive: isActive,
                customName: Self.readNullableText(statement, column: 7),
                customColor: Self.readNullableText(statement, column: 8),
                customIcon: Self.readNullableText(statement, column: 9)
            ))
        }

        return try rows.map { row in
            let routes = try fetchRoutes(macDeviceID: row.macDeviceID, ownerKey: row.ownerKey)
            return MobilePairedMac(
                macDeviceID: row.macDeviceID,
                displayName: row.displayName,
                routes: routes,
                createdAt: row.createdAt,
                lastSeenAt: row.lastSeenAt,
                isActive: row.isActive,
                stackUserID: row.stackUserID,
                teamID: row.teamID,
                customName: row.customName,
                customColor: row.customColor,
                customIcon: row.customIcon,
                instanceTag: row.instanceTag
            )
        }
    }

    func fetchRoutes(macDeviceID: String, ownerKey: String) throws -> [CmxAttachRoute] {
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

    static func encodeRoute(_ route: CmxAttachRoute) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(route)
        guard let string = String(data: data, encoding: .utf8) else {
            throw MobilePairedMacStoreError.decodeFailed
        }
        return string
    }

    static func readNullableText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }
}
