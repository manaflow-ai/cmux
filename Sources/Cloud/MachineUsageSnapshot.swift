import Foundation

/// One machine's usage readout: the row shows `totals` labeled with
/// `periodDays`. `vmID` is the id `GET /api/vm` returns as the machine id, so
/// it matches ``MachineSnapshot/id`` directly.
struct MachineUsageSnapshot: Equatable, Sendable {
    let vmID: String
    /// The provider machine id, the `id` that `GET /api/vm` lists. Rows key
    /// on it when present because `vmID` is the backend's own uuid.
    let providerVmID: String?
    let displayName: String?
    let periodDays: Int
    let asOf: Date?
    let totals: MachineUsageTotals
}

