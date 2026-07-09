public import Foundation

// Device-local iroh EndpointId trust pin. Split out of `MobilePairedMacStore`
// to keep that file under the Swift file-length budget. Pure move: the schema
// migration and the pin write are unchanged from their prior in-file form and
// run on the same `MobilePairedMacStore` actor, so `try migrateToV5()` from
// `runMigrations` still dispatches here normally.
extension MobilePairedMacStore {
    /// v5: device-local iroh EndpointId trust pin. Additive and nullable so
    /// existing rows start unpinned; route refresh/upsert writes deliberately do
    /// not touch this column.
    func migrateToV5() throws {
        let existing = try tableColumns("paired_macs")
        if !existing.contains("pinned_iroh_endpoint_id") {
            try exec("ALTER TABLE paired_macs ADD COLUMN pinned_iroh_endpoint_id TEXT;")
        }
    }

    /// Persist the device-local iroh EndpointId trust pin for one paired Mac.
    public func setPinnedIrohEndpointID(
        macDeviceID: String,
        endpointID: String,
        stackUserID: String? = nil,
        teamID: String? = nil,
        now: Date = Date()
    ) throws {
        _ = now
        try ensureReady()
        try exec("""
            UPDATE paired_macs
            SET pinned_iroh_endpoint_id = ?
            WHERE mac_device_id = ? AND owner_key = ?;
        """, binding: [
            .text(endpointID),
            .text(macDeviceID),
            .text("\(stackUserID ?? "")\u{1F}\(teamID ?? "")"),
        ])
    }
}
