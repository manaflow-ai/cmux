import Foundation
public import Observation

/// The last enroll or doctor report of each machine, by app machine id, for this run of the app
/// (the Machines section's status dot). Kept in memory: a relaunch shows no status until the next
/// Check Machine or add.
@Observable
public final class MachineHealthStore {
    public private(set) var reports: [String: HostReport] = [:]

    public init() {}

    public func record(_ machineID: String, _ report: HostReport) {
        reports[machineID] = report
    }
}

/// One machine of the Machines section (a value snapshot).
public nonisolated struct MachineSectionRow: Identifiable, Hashable, Sendable {
    /// The machine id (`workspace.newOnMachine`'s `machine`).
    public let id: String
    public let name: String
    public let isConnected: Bool
    public let isLocal: Bool
    /// The last check's outcome; nil before one ran in this app run.
    public let health: HostHealth?
    /// The step the last check flagged (its first failure, else its first warning).
    public let healthStep: HostStep?

    public init(id: String, name: String, isConnected: Bool, isLocal: Bool, health: HostHealth? = nil, healthStep: HostStep? = nil) {
        self.id = id
        self.name = name
        self.isConnected = isConnected
        self.isLocal = isLocal
        self.health = health
        self.healthStep = healthStep
    }

    /// The tooltip of the status dot: which step the last check flagged.
    public var healthHelp: String? {
        switch health {
        case .ok: AddMachineStrings.healthOK
        case .warning: AddMachineStrings.healthWarning(healthStep.map(AddMachineStrings.step) ?? "")
        case .failing: AddMachineStrings.healthFailing(healthStep.map(AddMachineStrings.step) ?? "")
        case nil: nil
        }
    }
}

/// The Machines section's rows: this Mac, then every Cloud, SSH and server machine the app knows,
/// with whether each is connected and how its last check went.
@Observable
public final class MachineSectionModel {
    public private(set) var rows: [MachineSectionRow] = []

    public init() {}

    public func update(_ next: [MachineSectionRow]) {
        if next != rows { rows = next }
    }
}
