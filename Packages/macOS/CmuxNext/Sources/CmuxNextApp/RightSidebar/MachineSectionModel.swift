import CmuxNextServer

extension MachineSectionModel {
    /// The rows of `machines` now, each with its kind, its link state and its last check from `health`;
    /// then the sample machines while `machines.section.fixture` is on.
    static func rows(_ machines: MachineRegistry, health: MachineHealthStore) -> [MachineSectionRow] {
        let live = machines.daemons.map { daemon in
            let state = daemon.store.connectionState
            let connected = if case .connected = state { true } else { false }
            let connecting = state == .connecting
            let name = daemon.isLocal ? RightSidebarStrings.thisMac : machines.machineName(daemon.machineID) ?? daemon.machineID
            let report = health.reports[daemon.machineID]
            return MachineSectionRow(id: daemon.machineID, name: name, isConnected: connected, isLocal: daemon.isLocal,
                                     kind: kind(daemon.machineID, isLocal: daemon.isLocal, in: machines), isConnecting: connecting,
                                     health: report?.health, healthStep: report?.worstStep?.step)
        }
        return ServerTunables.machinesFixture.value ? live + fixtureRows : live
    }

    /// What `machineID` is in `machines`: this Mac, a Cloud machine, an SSH machine, else a paired server.
    static func kind(_ machineID: String, isLocal: Bool, in machines: MachineRegistry) -> MachineKind {
        if isLocal { return .local }
        if machines.session(machineID) != nil { return .cloud }
        if machines.sshSession(machineID) != nil { return .ssh }
        return .server
    }
}
