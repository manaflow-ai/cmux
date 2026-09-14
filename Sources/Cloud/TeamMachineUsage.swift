import Foundation

/// The team-wide usage payload. `kind == .unavailable` means the backend has no
/// usage store for this team (no rows are rendered, no error is surfaced).
struct TeamMachineUsage: Equatable, Sendable {
    enum Kind: String, Sendable {
        case ready
        case unavailable
    }

    let teamID: String
    let periodDays: Int
    let kind: Kind
    let asOf: Date?
    let machines: [MachineUsageSnapshot]

    /// The lookup the machines panel keys rows by. Empty when the backend says
    /// usage is unavailable; blank ids are dropped; the first entry wins when
    /// the backend repeats a machine.
    var byMachineID: [String: MachineUsageSnapshot] {
        guard kind == .ready else { return [:] }
        var result: [String: MachineUsageSnapshot] = [:]
        for machine in machines {
            for key in [machine.providerVmID ?? "", machine.vmID] where !key.isEmpty && result[key] == nil {
                result[key] = machine
            }
        }
        return result
    }
}

