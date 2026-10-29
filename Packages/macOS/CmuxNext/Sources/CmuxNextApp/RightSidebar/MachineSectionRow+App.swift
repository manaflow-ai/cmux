import CmuxNextServer

/// Main actor: it reads the machine registry and each daemon's store.
@MainActor
extension MachineSectionRow {
    /// The rows of `machines` now, each with its kind, its link state and its last check from `health`;
    /// then the sample machines while `machines.section.fixture` is on; then the machines that joined
    /// with a one-line token (`joined`, empty while Labs `labs.machineJoin` is off) that the app does
    /// not already connect to (kind `.joined`, their own group).
    /// A joined machine the app also connects to (its `meshPeerId` is a daemon's id) stays one row:
    /// the daemon's, in that daemon's kind, carrying the joined machine so its menu offers Check,
    /// Rotate and Revoke.
    static func rows(_ machines: MachineRegistry, health: MachineHealthStore, joined: JoinedMachineStore? = nil) -> [MachineSectionRow] {
        let all = joined?.machines ?? []
        let byPeer = Dictionary(all.compactMap { machine in machine.meshPeerId.map { ($0, machine) } }, uniquingKeysWith: { first, _ in first })
        let live = machines.daemons.map { daemon in
            let state = daemon.store.connectionState
            let connected = if case .connected = state { true } else { false }
            let connecting = state == .connecting
            let name = daemon.isLocal ? RightSidebarStrings.thisMac : machines.machineName(daemon.machineID) ?? daemon.machineID
            let report = health.reports[daemon.machineID]
            return MachineSectionRow(id: daemon.machineID, name: name, isConnected: connected, isLocal: daemon.isLocal,
                                     kind: kind(daemon.machineID, isLocal: daemon.isLocal, in: machines), isConnecting: connecting,
                                     health: report?.health, healthStep: report?.worstStep?.step,
                                     joined: daemon.isLocal ? nil : byPeer[daemon.machineID])
        }
        let known = Set(machines.daemons.filter { !$0.isLocal }.map(\.machineID))
        let mesh = all.filter { $0.meshPeerId.map { !known.contains($0) } ?? true }
            .map { MachineSectionRow.joined($0, health: health.reports[JoinedMachine.healthID($0.id)]) }
        return (ServerTunables.machinesFixture.value ? live + fixtures : live) + mesh
    }

    /// What `machineID` is in `machines`: this Mac, a Cloud machine, an SSH machine, else a paired server.
    static func kind(_ machineID: String, isLocal: Bool, in machines: MachineRegistry) -> MachineKind {
        if isLocal { return .local }
        if machines.session(machineID) != nil { return .cloud }
        if machines.sshSession(machineID) != nil { return .ssh }
        return .server
    }
}
