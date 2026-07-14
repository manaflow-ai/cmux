import CMUXMobileCore
import Foundation

extension MobilePairedMacStore: MobilePairedMacStoring {
    /// Restore a rejected upsert and its prior selection as one SQLite commit.
    public func rollbackRejectedUpsert(
        _ rollback: MobilePairedMacUpsertRollback
    ) async throws {
        try rollbackRejectedUpsertAtomically(rollback)
    }

    func rollbackRejectedUpsertAtomically(
        _ rollback: MobilePairedMacUpsertRollback
    ) throws {
        try ensureReady()
        try transaction {
            let rejectedOwnerKey = pairedMacOwnerKey(
                stackUserID: rollback.rejectedStackUserID,
                teamID: rollback.rejectedTeamID
            )
            let previousOwnerKey = rollback.previousMac.map {
                pairedMacOwnerKey(stackUserID: $0.stackUserID, teamID: $0.teamID)
            }
            if previousOwnerKey != rejectedOwnerKey {
                try exec(
                    "DELETE FROM paired_macs WHERE mac_device_id = ? AND owner_key = ?;",
                    binding: [
                        .text(rollback.rejectedMacDeviceID),
                        .text(rejectedOwnerKey),
                    ]
                )
            }

            if let previousMac = rollback.previousMac, let previousOwnerKey {
                if previousMac.isActive {
                    try clearActiveMacs(
                        stackUserID: previousMac.stackUserID,
                        teamID: previousMac.teamID
                    )
                }
                try upsertMacRow(
                    macDeviceID: previousMac.macDeviceID,
                    ownerKey: previousOwnerKey,
                    displayName: previousMac.displayName,
                    instanceTag: previousMac.instanceTag,
                    stackUserID: previousMac.stackUserID,
                    teamID: previousMac.teamID,
                    createdAt: previousMac.createdAt,
                    lastSeenAt: rollback.compensatingTimestamp,
                    isActive: previousMac.isActive
                )
                try replaceRoutes(previousMac.routes, for: previousMac, ownerKey: previousOwnerKey)
                try exec("""
                    UPDATE paired_macs
                    SET custom_name = ?, custom_color = ?, custom_icon = ?
                    WHERE mac_device_id = ? AND owner_key = ?;
                """, binding: [
                    previousMac.customName.map(BindValue.text) ?? .null,
                    previousMac.customColor.map(BindValue.text) ?? .null,
                    previousMac.customIcon.map(BindValue.text) ?? .null,
                    .text(previousMac.macDeviceID),
                    .text(previousOwnerKey),
                ])
            }

            if let previousActiveMac = rollback.previousActiveMac,
               !samePairedMacIdentity(previousActiveMac, rollback.previousMac) {
                try clearActiveMacs(
                    stackUserID: previousActiveMac.stackUserID,
                    teamID: previousActiveMac.teamID
                )
                try exec(
                    "UPDATE paired_macs SET is_active = 1 WHERE mac_device_id = ? AND owner_key = ?;",
                    binding: [
                        .text(previousActiveMac.macDeviceID),
                        .text(pairedMacOwnerKey(
                            stackUserID: previousActiveMac.stackUserID,
                            teamID: previousActiveMac.teamID
                        )),
                    ]
                )
            }
        }
    }

    private func replaceRoutes(
        _ routes: [CmxAttachRoute],
        for mac: MobilePairedMac,
        ownerKey: String
    ) throws {
        try exec(
            "DELETE FROM mac_routes WHERE mac_device_id = ? AND owner_key = ?;",
            binding: [.text(mac.macDeviceID), .text(ownerKey)]
        )
        for route in routes {
            try exec("""
                INSERT INTO mac_routes (mac_device_id, owner_key, route_id, kind, endpoint_json, priority)
                VALUES (?, ?, ?, ?, ?, ?);
            """, binding: [
                .text(mac.macDeviceID),
                .text(ownerKey),
                .text(route.id),
                .text(route.kind.rawValue),
                .text(try Self.encodeRoute(route)),
                .int(Int64(route.priority)),
            ])
        }
    }

    private func samePairedMacIdentity(
        _ lhs: MobilePairedMac,
        _ rhs: MobilePairedMac?
    ) -> Bool {
        lhs.macDeviceID == rhs?.macDeviceID
            && lhs.stackUserID == rhs?.stackUserID
            && lhs.teamID == rhs?.teamID
    }

    private func pairedMacOwnerKey(stackUserID: String?, teamID: String?) -> String {
        "\(stackUserID ?? "")\u{1F}\(teamID ?? "")"
    }
}
