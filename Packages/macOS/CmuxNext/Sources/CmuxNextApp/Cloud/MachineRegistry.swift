import CmuxNextActions
import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Observation

/// Every daemon tree the app shows: the local daemon plus one connection per
/// Cloud machine and per SSH machine (`SSHService`). Each is a separate tree
/// with its own store, shown as its own sidebar section. Workspaces never mix machines (REWRITE.md "no
/// mixed-machine workspaces in v1"), so a workspace, pane, or tab resolves
/// to exactly one daemon, and every command for it goes there.
@Observable
final class MachineRegistry {
    static let localID = "local"

    let local: DaemonService
    /// Cloud machines in sidebar order (newest last).
    private(set) var cloud: [CloudMachineSession] = []
    /// SSH machines in the order they were added.
    private(set) var ssh: [SSHMachineSession] = []

    /// Whether an administrator turned off a feature (`DisabledFeatures`):
    /// a Cloud machine is not reachable with `cloud` off, an SSH machine
    /// not with `remoteHosts` off, so no path opens work on it.
    @ObservationIgnored var isFeatureDisabled: (ActionFeature) -> Bool = { _ in false }

    init(local: DaemonService) {
        self.local = local
    }

    /// Local first, then Cloud machines, then SSH machines.
    var daemons: [DaemonService] { [local] + remoteDaemons }

    /// Every daemon that is not the local one.
    var remoteDaemons: [DaemonService] { cloud.map(\.daemon) + ssh.map(\.daemon) }

    func session(_ machineID: String) -> CloudMachineSession? {
        cloud.first { $0.machineID == machineID }
    }

    func sshSession(_ machineID: String) -> SSHMachineSession? {
        ssh.first { $0.machineID == machineID }
    }

    /// The machine's daemon even while its feature is turned off (its
    /// endpoint refuses); for routing that must not fall back to this Mac.
    func anyDaemon(machine machineID: String) -> DaemonService? {
        machineID == Self.localID ? local : session(machineID)?.daemon ?? sshSession(machineID)?.daemon
    }

    func daemon(machine machineID: String) -> DaemonService? {
        if machineID == Self.localID { return local }
        if let cloud = session(machineID) { return isFeatureDisabled(.cloud) ? nil : cloud.daemon }
        return isFeatureDisabled(.remoteHosts) ? nil : sshSession(machineID)?.daemon
    }

    /// The empty-workspace repair of `machineID` (the local one for local
    /// or an unknown machine).
    func emptyWorkspaceRepair(_ machineID: String?, local fallback: EmptyWorkspaceRepair) -> EmptyWorkspaceRepair {
        guard let machineID else { return fallback }
        return session(machineID)?.emptyWorkspaces ?? sshSession(machineID)?.emptyWorkspaces ?? fallback
    }

    /// The short name on a remote machine's tabs: the host (never the
    /// session), or the Cloud machine's title.
    func machineBadge(_ machineID: String) -> String? {
        session(machineID)?.machine.title ?? sshSession(machineID)?.host.destination.displayName
    }

    /// The sidebar name of a remote machine, nil for local.
    func machineName(_ machineID: String) -> String? {
        session(machineID)?.machine.title ?? sshSession(machineID)?.host.label
    }

    /// What `daemon` can do for the app. A remote daemon never needs the
    /// home-only capabilities, nor, once the local daemon keeps personal
    /// state (`profiles-v1`), workspace groups and saved tab groups.
    func compatibility(of daemon: DaemonService) -> DaemonCompatibility? {
        guard !daemon.isLocal else { return daemon.compatibility }
        var notNeeded = Set(DaemonCapabilities.shared.homeOnly)
        if local.supports(DaemonCapabilities.shared.profiles) { notNeeded.formUnion(DaemonCapabilities.shared.personalOnHome) }
        return daemon.compatibility(notNeeded: notNeeded)
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
        for daemon in remoteDaemons where daemon.store.pane(pane.handle) === pane { return daemon }
        return local
    }

    /// The daemon holding `tab` (by object identity).
    func daemon(forTab tab: TabModel) -> DaemonService {
        for daemon in remoteDaemons where daemon.store.tab(surface: tab.surface) === tab { return daemon }
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

    // MARK: SSH sessions (SSHService only)

    func add(_ session: SSHMachineSession) {
        guard sshSession(session.machineID) == nil else { return }
        ssh.append(session)
    }

    func removeSSH(_ machineID: String) -> SSHMachineSession? {
        guard let index = ssh.firstIndex(where: { $0.machineID == machineID }) else { return nil }
        return ssh.remove(at: index)
    }
}
