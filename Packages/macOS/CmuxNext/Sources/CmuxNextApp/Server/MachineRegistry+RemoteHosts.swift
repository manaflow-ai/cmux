import CmuxNextRemote
import CmuxNextRemoteHosting
import Foundation

extension ServerMachineSession: RemoteHostSession {}

/// `MachineRegistry` as the remote hosts' registry (CmuxNextRemoteHosting): a host is a server
/// machine on the `tailnet` route, sharing `servers` with the paired servers.
@MainActor
final class AppRemoteHostRegistry: RemoteHostRegistry {
    private let machines: MachineRegistry
    private let paths: SSHPaths

    init(machines: MachineRegistry, bundleID: String?) {
        self.machines = machines
        paths = SSHPaths.standard(bundleID: bundleID)
    }

    var remoteHosts: [any RemoteHostSession] { machines.servers.filter(\.reach.isTailnetHost) }

    func remoteHost(_ machineID: String) -> (any RemoteHostSession)? { machines.server(machineID) }

    func addRemoteHost(_ reach: ServerReach, cli: URL?) -> any RemoteHostSession {
        // No SSH binary: the tailnet route never uses the SSH carrier.
        let session = ServerMachineSession(reach: reach, binary: nil, paths: paths, environment: SSHService.environment,
                                           localIdentity: { [machines] in machines.local.identity }, cli: cli)
        session.daemon.workTracker = machines.local.workTracker
        machines.add(session)
        return session
    }

    func removeRemoteHost(_ machineID: String) { _ = machines.removeServer(machineID) }

    func recordedRemoteHostIDs() -> Set<String> {
        let store = machines.local.store
        guard store.personal.isLoaded, !store.isProvisional else { return [] }
        return Set(store.personal.sessions.compactMap { record in
            record.transport.flatMap(SSHService.fields).flatMap(ServerReach.init(transportFields:))
                .flatMap { $0.isTailnetHost ? $0.machineID : nil }
        })
    }
}
