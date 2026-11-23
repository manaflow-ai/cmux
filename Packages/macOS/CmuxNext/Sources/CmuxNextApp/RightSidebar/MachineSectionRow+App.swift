import CmuxNextCloud
import CmuxNextServer

/// Main actor: it reads the machine registry and each daemon's store.
@MainActor
extension MachineSectionRow {
    /// The rows of `machines` now, each with its kind, its link state and its last check from `health`;
    /// then the sample machines while `machines.section.fixture` is on; then the person's machines that
    /// joined through the hub (`joined`: `cmux machine list`) that the app does not already connect to
    /// (kind `.joined`, their own group). A revoked machine has left: it has no row.
    /// A joined machine the app also connects to (its `meshPeerId` is a daemon's id) stays one row:
    /// the daemon's, in that daemon's kind, carrying the joined machine so its menu offers Check,
    /// Rotate and Revoke.
    /// A joined Mac the person opened through its acpmux route (`signedIn`: a server's machine id to the
    /// joined machine's id, ``ServerReachService/signedInMachines``) is that server's row, still under
    /// Joined and still carrying the joined machine, listed with the app's servers before the joined Macs
    /// reached through the hub. Once that joined machine is revoked or removed, its server has no row.
    /// A Cloud machine that is agent infrastructure (``CloudMachine/isAgentInfrastructure``: fleet lane
    /// hosts, peers and probes our tooling made under this account) has no row: it is not one of the
    /// person's own machines.
    static func rows(_ machines: MachineRegistry, health: MachineHealthStore, joined: JoinedMachineStore? = nil,
                     signedIn: [String: String] = [:]) -> [MachineSectionRow] {
        let all = (joined?.machines ?? []).filter { $0.state != .revoked }
        let byPeer = Dictionary(all.compactMap { machine in machine.meshPeerId.map { ($0, machine) } }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let live = machines.daemons.filter { machines.session($0.machineID)?.machine.isAgentInfrastructure != true && signedIn[$0.machineID].map { byID[$0] != nil } ?? true }.map { daemon in
            let state = daemon.store.connectionState
            // The store can report its socket as connected before the app has a usable daemon
            // transport (for example an enrolled host with acpmux but no cmux-tui). Such a row
            // must take the connect/recovery path instead of dispatching a doomed workspace action.
            let connected = if case .connected = state { daemon.connection != nil } else { false }
            let connecting = state == .connecting
            let name = daemon.isLocal ? RightSidebarStrings.thisMac : machines.machineName(daemon.machineID) ?? daemon.machineID
            let report = health.reports[daemon.machineID]
            let cloud = daemon.isLocal ? nil : machines.session(daemon.machineID)
            let ssh = machines.sshSession(daemon.machineID)
            let failed = ssh.map { $0.linkStatus.needsRecovery || $0.daemonFailure != nil } ?? false
            let failure = ssh.flatMap { failed ? RemoteStrings.sshError($0) : nil }
            return MachineSectionRow(id: daemon.machineID, name: name, isConnected: connected, isLocal: daemon.isLocal,
                                     kind: signedIn[daemon.machineID] != nil ? .joined : .linked(isLocal: daemon.isLocal, hasCloud: cloud != nil, hasSSH: ssh != nil),
                                     isConnecting: connecting, failed: failed, failure: failure,
                                     serverState: cloud.flatMap { .cloud($0.machine.status, stagePaused: $0.stage.isPaused, stageFailed: $0.stage.failure != nil) },
                                     health: report?.health, healthStep: report?.worstStep?.step,
                                     joined: daemon.isLocal ? nil : byPeer[daemon.machineID] ?? signedIn[daemon.machineID].flatMap { byID[$0] },
                                     symbol: daemon.store.identity?.machineSymbol)
        }
        let known = Set(machines.daemons.filter { !$0.isLocal }.map(\.machineID))
        let opened = Set(signedIn.filter { known.contains($0.key) }.values)
        let mesh = all.filter { ($0.meshPeerId.map { !known.contains($0) } ?? true) && !opened.contains($0.id) }
            .map { MachineSectionRow.joined($0, health: health.reports[JoinedMachine.healthID($0.id)]) }
        return (ServerTunables.machinesFixture.value ? live + fixtures : live) + mesh
    }
}
