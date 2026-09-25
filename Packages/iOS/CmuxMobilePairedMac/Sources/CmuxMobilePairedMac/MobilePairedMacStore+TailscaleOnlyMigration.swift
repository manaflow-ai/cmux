public import CMUXMobileCore
import Foundation
import SQLite3

extension MobilePairedMacStore {
    /// v13: the Tailscale Only method folded into Direct.
    ///
    /// A Computer whose pairing knows the Mac's device key (an Iroh route)
    /// becomes Direct, with every authorized Tailscale endpoint appended to its
    /// Direct addresses, so it keeps dialing exactly those endpoints. A
    /// pre-Iroh pairing has no key to verify; it returns to the default Iroh
    /// method, whose legacy compatibility still dials its granted raw route.
    func migrateToV13() throws {
        struct Row {
            let macDeviceID: String
            let ownerKey: String
            let directAddressesRawJSON: String?
            let hasIroh: Bool
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(
            db,
            """
            SELECT macs.mac_device_id, macs.owner_key, macs.direct_addresses,
                   EXISTS (
                       SELECT 1 FROM mac_routes routes
                       WHERE routes.mac_device_id = macs.mac_device_id
                         AND routes.owner_key = macs.owner_key
                         AND routes.kind = 'iroh'
                   )
            FROM paired_macs macs
            WHERE macs.connection_method = 'tailscale';
            """,
            -1,
            &statement,
            nil
        )
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let macDeviceID = Self.readNullableText(statement, column: 0),
                  let ownerKey = Self.readNullableText(statement, column: 1) else { continue }
            rows.append(Row(
                macDeviceID: macDeviceID,
                ownerKey: ownerKey,
                directAddressesRawJSON: Self.readNullableText(statement, column: 2),
                hasIroh: sqlite3_column_int(statement, 3) != 0
            ))
        }

        for row in rows {
            guard row.hasIroh else {
                try exec(
                    "UPDATE paired_macs SET connection_method = NULL WHERE mac_device_id = ? AND owner_key = ?;",
                    binding: [.text(row.macDeviceID), .text(row.ownerKey)]
                )
                continue
            }
            let grants = try fetchLegacyTailscaleRoutes(macDeviceID: row.macDeviceID, ownerKey: row.ownerKey)
            let existing = MobilePairedMac(
                macDeviceID: row.macDeviceID,
                displayName: nil,
                routes: [],
                createdAt: .distantPast,
                lastSeenAt: .distantPast,
                isActive: false,
                stackUserID: nil,
                directAddressesRawJSON: row.directAddressesRawJSON
            ).directAddresses
            let merged = Self.appendingTailscaleAddresses(from: grants, to: existing)
            try exec(
                """
                UPDATE paired_macs SET connection_method = 'direct', direct_addresses = ?
                WHERE mac_device_id = ? AND owner_key = ?;
                """,
                binding: [
                    MobilePairedMac.encodeDirectAddresses(merged).map { .text($0) } ?? .null,
                    .text(row.macDeviceID),
                    .text(row.ownerKey),
                ]
            )
        }
    }

    /// Appends each Tailscale host and port not already present as an enabled
    /// Direct address labeled "Tailscale".
    public static func appendingTailscaleAddresses(
        from routes: [CmxAttachRoute],
        to addresses: [MobilePairedMacDirectAddress]
    ) -> [MobilePairedMacDirectAddress] {
        var merged = addresses
        for route in routes {
            guard route.kind == .tailscale, case let .hostPort(host, port) = route.endpoint,
                  !merged.contains(where: { $0.address == host && $0.port == port }) else { continue }
            merged.append(MobilePairedMacDirectAddress(address: host, port: port, label: "Tailscale"))
        }
        return merged
    }
}
