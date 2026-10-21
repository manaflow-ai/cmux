import Observation

/// The Cloud section's rows: this Mac, then every Cloud, SSH and server machine
/// the app knows (`MachineRegistry.daemons`), with whether each is connected.
@MainActor
@Observable
final class MachineSectionModel {
    private(set) var rows: [MachineSectionRow] = []

    func update(_ next: [MachineSectionRow]) {
        if next != rows { rows = next }
    }
}

extension MachineSectionModel {
    /// The rows of `machines` now.
    static func rows(_ machines: MachineRegistry) -> [MachineSectionRow] {
        machines.daemons.map { daemon in
            let connected = if case .connected = daemon.store.connectionState { true } else { false }
            let name = daemon.isLocal ? RightSidebarStrings.thisMac : machines.machineName(daemon.machineID) ?? daemon.machineID
            return MachineSectionRow(id: daemon.machineID, name: name, isConnected: connected, isLocal: daemon.isLocal)
        }
    }
}
