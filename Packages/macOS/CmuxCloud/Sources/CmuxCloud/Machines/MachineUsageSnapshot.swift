import Foundation

/// One machine's usage readout: the row shows `totals` labeled with
/// `periodDays`. `vmID` is the id `GET /api/vm` returns as the machine id, so
/// it matches ``MachineSnapshot/id`` directly.
public struct MachineUsageSnapshot: Equatable, Sendable {
    public init(
        vmID: String,
        providerVmID: String? = nil,
        displayName: String? = nil,
        periodDays: Int,
        asOf: Date? = nil,
        totals: MachineUsageTotals
    ) {
        self.vmID = vmID
        self.providerVmID = providerVmID
        self.displayName = displayName
        self.periodDays = periodDays
        self.asOf = asOf
        self.totals = totals
    }

    public let vmID: String
    /// The provider machine id, the `id` that `GET /api/vm` lists. Rows key
    /// on it when present because `vmID` is the backend's own uuid.
    public let providerVmID: String?
    public let displayName: String?
    public let periodDays: Int
    public let asOf: Date?
    public let totals: MachineUsageTotals
}
