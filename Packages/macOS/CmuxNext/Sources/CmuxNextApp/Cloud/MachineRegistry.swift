import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Observation

/// Every daemon tree the app shows: the local daemon plus one connection per
/// Cloud machine. Each is a separate tree with its own store, shown as its
/// own sidebar section. Workspaces never mix machines (REWRITE.md "no
/// mixed-machine workspaces in v1"), so a workspace, pane, or tab resolves
/// to exactly one daemon, and every command for it goes there.
@Observable
final class MachineRegistry {
    static let localID = "local"

    let local: DaemonService
    /// Cloud machines in sidebar order (newest last).
    private(set) var cloud: [CloudMachineSession] = []

    init(local: DaemonService) {
        self.local = local
    }

    /// Local first, then Cloud machines.
    var daemons: [DaemonService] { [local] + cloud.map(\.daemon) }

    func session(_ machineID: String) -> CloudMachineSession? {
        cloud.first { $0.machineID == machineID }
    }

    func daemon(machine machineID: String) -> DaemonService? {
        machineID == Self.localID ? local : session(machineID)?.daemon
    }

    /// The daemon serving session `sessionID` (its `registry_id` UUID), on
    /// any machine. Session ids are the stable key across machines: a
    /// machine's daemon can restart, be upgraded or be re-linked, and its
    /// session id stays the same.
    func daemon(session sessionID: String) -> DaemonService? {
        let wanted = sessionID.lowercased()
        return daemons.first { $0.identity?.sessionID == wanted }
    }

    /// The daemon whose tree holds workspace `id` (`WorkspaceModel.id`).
    func daemon(forWorkspace id: String) -> DaemonService? {
        daemons.first { daemon in daemon.store.workspaces.contains { $0.id == id } }
    }

    func workspace(id: String) -> (WorkspaceModel, DaemonService)? {
        for daemon in daemons {
            if let workspace = daemon.store.workspaces.first(where: { $0.id == id }) { return (workspace, daemon) }
        }
        return nil
    }

    /// The daemon holding pane `pane` (by object identity).
    func daemon(forPane pane: PaneModel) -> DaemonService {
        for daemon in cloud.map(\.daemon) where daemon.store.pane(pane.handle) === pane { return daemon }
        return local
    }

    /// The daemon holding `tab` (by object identity).
    func daemon(forTab tab: TabModel) -> DaemonService {
        for daemon in cloud.map(\.daemon) where daemon.store.tab(surface: tab.surface) === tab { return daemon }
        return local
    }

    /// Every workspace on every machine, local first.
    var allWorkspaces: [(WorkspaceModel, DaemonService)] {
        daemons.flatMap { daemon in daemon.store.workspaces.map { ($0, daemon) } }
    }

    // MARK: Cloud sessions (CloudService only)

    func add(_ session: CloudMachineSession) {
        guard self.session(session.machineID) == nil else { return }
        cloud.append(session)
    }

    func remove(_ machineID: String) -> CloudMachineSession? {
        guard let index = cloud.firstIndex(where: { $0.machineID == machineID }) else { return nil }
        return cloud.remove(at: index)
    }
}

/// One Cloud machine: its `/api/vm` record, its link process, and the
/// daemon connection over the link socket.
@Observable
final class CloudMachineSession {
    let machineID: String
    var machine: CloudMachine
    let daemon: DaemonService
    @ObservationIgnored let link: CloudMachineLink
    /// Repairs an empty workspace on this machine (never on another).
    @ObservationIgnored private(set) var emptyWorkspaces: EmptyWorkspaceRepair!

    init(machine: CloudMachine, link: CloudMachineLink) {
        machineID = machine.id
        self.machine = machine
        self.link = link
        daemon = DaemonService(machineID: machine.id)
        emptyWorkspaces = EmptyWorkspaceRepair(daemon: daemon)
    }

    /// Connects when the machine is live; the link restarts as needed.
    func connect() {
        guard machine.status.isLive else { return }
        let link = link
        daemon.start(remote: { try await link.socketPath() })
    }

    func disconnect() {
        daemon.shutdownConnection()
        let link = link
        // task-owner: teardown hop; link.stop() is terminal and re-checked after every await in start
        Task { await link.stop() }
    }
}
