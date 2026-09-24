import CMUXMobileCore
import Foundation
import SQLite3

extension MobilePairedMacStore: MobilePairedMacIdentityMigrating {
    /// Reconcile only exact endpoint/account/team/build matches. Unmatched
    /// metadata stays in storage; names and IP addresses never establish identity.
    public func reconcileLegacyIdentities(
        with directory: [MobilePairedMacDirectoryIdentity],
        stackUserID: String,
        teamID: String?
    ) throws -> [MobilePairedMacIdentityReplacement] {
        try ensureReady()
        guard !stackUserID.isEmpty else { return [] }
        let rows = try loadAll(stackUserID: stackUserID, teamID: teamID)
            .filter { $0.stackUserID == stackUserID && $0.teamID == teamID }
        let currentIDs = Set(directory.map(\.pairingID))
        let byEndpoint = Dictionary(grouping: directory.flatMap { identity in
            Self.irohEndpoints(identity.routes).map { ($0, identity) }
        }, by: { $0.0 })

        try transaction {
            // This table belongs to the opt-in upgrade, not the normal schema.
            // Do not use a global "done" bit: an offline Mac can appear later.
            try exec("""
                CREATE TABLE IF NOT EXISTS paired_mac_v2_identity_aliases (
                    owner_key TEXT NOT NULL,
                    old_device_id TEXT NOT NULL,
                    new_device_id TEXT NOT NULL,
                    instance_tag TEXT NOT NULL,
                    PRIMARY KEY (owner_key, old_device_id)
                );
                """)
            let migrated = Set(try identityReplacements(stackUserID: stackUserID, teamID: teamID)
                .map(\.oldPairingID))
            for old in rows where !currentIDs.contains(old.id) {
                if migrated.contains(old.id) {
                    // A stale restore must not overwrite choices made after
                    // this computer was already migrated.
                    try exec("DELETE FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;",
                             binding: [.text(old.macDeviceID), .text(Self.ownerKey(
                                stackUserID: stackUserID, teamID: teamID, instanceTag: old.instanceTag
                             ))])
                    continue
                }
                guard let tag = old.instanceTag else { continue }
                let matches = Self.irohEndpoints(old.routes).flatMap { byEndpoint[$0] ?? [] }
                    .map(\.1).filter { $0.instanceTag == tag }
                let matchingIDs = Set(matches.map(\.pairingID))
                guard matchingIDs.count == 1, let replacement = matches.first else { continue }
                try migrateIdentity(old, to: replacement, stackUserID: stackUserID, teamID: teamID)
            }
        }
        return try identityReplacements(stackUserID: stackUserID, teamID: teamID)
    }

    private static func irohEndpoints(_ routes: [CmxAttachRoute]) -> Set<String> {
        Set(routes.compactMap { route in
            guard route.kind == .iroh, case .peer(let identity, _) = route.endpoint else { return nil }
            return identity.endpointID
        })
    }

    private func migrateIdentity(
        _ old: MobilePairedMac,
        to current: MobilePairedMacDirectoryIdentity,
        stackUserID: String,
        teamID: String?
    ) throws {
        let owner = Self.ownerKey(stackUserID: stackUserID, teamID: teamID, instanceTag: old.instanceTag)
        let target = try loadAll(stackUserID: stackUserID, teamID: teamID)
            .first { $0.id == current.pairingID && $0.teamID == teamID }
        // Create the destination before copying its foreign-keyed removals.
        // Existing v2 customizations win; missing values inherit the old row.
        try exec("""
            INSERT OR IGNORE INTO paired_macs (
                mac_device_id, owner_key, display_name, stack_user_id, team_id,
                created_at, last_seen_at, is_active, custom_name, custom_color,
                custom_icon, instance_tag, connection_method, direct_addresses
            ) SELECT ?, owner_key, display_name, stack_user_id, team_id,
                created_at, last_seen_at, 0, custom_name, custom_color,
                custom_icon, instance_tag, connection_method, direct_addresses
              FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;
            """, binding: [.text(current.deviceID), .text(old.macDeviceID), .text(owner)])
        for column in ["custom_name", "custom_color", "custom_icon", "connection_method", "direct_addresses"] {
            try exec("""
                UPDATE paired_macs SET \(column) = COALESCE(\(column), (
                    SELECT \(column) FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?
                )) WHERE mac_device_id = ? AND owner_key = ?;
                """, binding: [.text(old.macDeviceID), .text(owner), .text(current.deviceID), .text(owner)])
        }
        try exec("""
            INSERT OR IGNORE INTO mac_route_removals (mac_device_id, owner_key, kind, endpoint_json)
            SELECT ?, owner_key, kind, endpoint_json FROM mac_route_removals
            WHERE mac_device_id = ? AND owner_key = ?;
            """, binding: [.text(current.deviceID), .text(old.macDeviceID), .text(owner)])
        // The directory supplies current routes. No old credential or local
        // legacy transport grant is promoted into v2 authority.
        try upsert(macDeviceID: current.deviceID, displayName: target?.displayName ?? old.displayName,
                   routes: current.routes, instanceTag: current.instanceTag,
                   markActive: old.isActive || target?.isActive == true,
                   stackUserID: stackUserID, teamID: teamID,
                   now: max(old.lastSeenAt, target?.lastSeenAt ?? old.lastSeenAt))
        try exec("""
            UPDATE paired_macs SET created_at = MIN(created_at, ?)
            WHERE mac_device_id = ? AND owner_key = ?;
            """, binding: [.real(old.createdAt.timeIntervalSince1970), .text(current.deviceID), .text(owner)])
        try exec("""
            INSERT INTO paired_mac_v2_identity_aliases (owner_key, old_device_id, new_device_id, instance_tag)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(owner_key, old_device_id) DO UPDATE SET new_device_id = excluded.new_device_id;
            """, binding: [.text(owner), .text(old.macDeviceID), .text(current.deviceID), .text(current.instanceTag)])
        try exec("DELETE FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;",
                 binding: [.text(old.macDeviceID), .text(owner)])
    }

    private func identityReplacements(stackUserID: String, teamID: String?) throws -> [MobilePairedMacIdentityReplacement] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT alias.old_device_id, alias.new_device_id, alias.instance_tag
            FROM paired_mac_v2_identity_aliases alias
            JOIN paired_macs current ON current.mac_device_id = alias.new_device_id
              AND current.owner_key = alias.owner_key
            WHERE current.stack_user_id = ? AND current.team_id IS ?;
            """
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else { throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage()) }
        try bind(statement: statement, parameters: [.text(stackUserID), teamID.map(BindValue.text) ?? .null])
        var result: [MobilePairedMacIdentityReplacement] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage()) }
            guard let old = Self.readNullableText(statement, column: 0),
                  let new = Self.readNullableText(statement, column: 1),
                  let tag = Self.readNullableText(statement, column: 2) else { continue }
            result.append(.init(oldPairingID: MobilePairedMac.pairingID(macDeviceID: old, instanceTag: tag),
                                newPairingID: MobilePairedMac.pairingID(macDeviceID: new, instanceTag: tag)))
        }
    }
}
