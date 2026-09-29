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
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            // An iteration error must fail the migration transaction (and
            // retry on the next open), not silently commit v13 with some
            // 'tailscale' rows left unconverted.
            guard step == SQLITE_ROW else {
                throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
            }
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
            let merged = existing.appendingTailscaleAddresses(from: grants)
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
            // The grants became Direct addresses; leaving them would let the
            // Iroh compatibility path resurrect an endpoint the user later
            // removes from the Direct list.
            try exec(
                "DELETE FROM legacy_tailscale_route_grants WHERE mac_device_id = ? AND owner_key = ?;",
                binding: [.text(row.macDeviceID), .text(row.ownerKey)]
            )
        }
    }

}

/// Reconciliation of the pairing-code-derived Direct addresses against a
/// freshly authorized route set, shared by the v13 migration and the live
/// pairing-code conversion.
public extension [MobilePairedMacDirectAddress] {
    /// Reconciles the pairing-code-derived subset (entries whose ``origin``
    /// is ``MobilePairedMacDirectAddress/pairingCodeOrigin``) against a
    /// freshly authorized route set: stale derived entries the new code no
    /// longer names are dropped (a replacement scan replaces, so old
    /// endpoints cannot pile up and crowd out the live one), a matching
    /// entry is re-enabled (an authorization naming a disabled endpoint must
    /// leave something dialable), and new endpoints are appended with the
    /// given transport marker. Re-enabling applies to any matching entry,
    /// hand-added or derived: the code names that exact endpoint, so the
    /// scan is the user's explicit intent to dial it. Hand-added entries
    /// (no ``MobilePairedMacDirectAddress/origin``) are exempt only from
    /// the stale-entry removal above; the display label carries no meaning.
    func appendingTailscaleAddresses(
        from routes: [CmxAttachRoute],
        transport: String? = nil
    ) -> [MobilePairedMacDirectAddress] {
        let authorized = routes.compactMap { route -> (host: String, port: Int)? in
            guard route.kind == .tailscale, case let .hostPort(host, port) = route.endpoint else { return nil }
            return (host, port)
        }
        var merged = filter { entry in
            entry.origin != MobilePairedMacDirectAddress.pairingCodeOrigin
                || authorized.contains { $0.host == entry.address && $0.port == entry.port }
        }
        for (host, port) in authorized {
            if let index = merged.firstIndex(where: { $0.address == host && $0.port == port }) {
                merged[index].enabled = true
                continue
            }
            merged.append(MobilePairedMacDirectAddress(
                address: host, port: port, label: "Tailscale",
                transport: transport,
                origin: MobilePairedMacDirectAddress.pairingCodeOrigin))
        }
        return merged
    }
}
