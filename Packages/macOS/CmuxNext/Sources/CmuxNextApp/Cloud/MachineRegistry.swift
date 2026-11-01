import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextWorkspaceRepair
import Foundation
import Observation

/// Every daemon tree the app shows: the local daemon plus one connection per
/// Cloud machine, per SSH machine (`SSHService`) and per paired server
/// (`ServerReachService`). Each is a separate tree
/// with its own store, shown as its own sidebar section. Workspaces never mix machines (REWRITE.md "no
/// mixed-machine workspaces in v1"), so a workspace, pane, or tab resolves
/// to exactly one daemon, and every command for it goes there.
@Observable
final class MachineRegistry {
    static let localID = "local"

    /// Whether `machineID` names a Cloud machine. A machine that is not in the registry has no typed
    /// kind here, so the id decides: SSH machines are `ssh-…` (`SSHHost.machineID`), paired servers
    /// `server-…` (`ServerReach.machineID`), this Mac `local`; every other id is a Cloud machine.
    static func isCloudMachineID(_ machineID: String) -> Bool {
        machineID != localID && !nonCloudIDPrefixes.contains { machineID.hasPrefix($0) }
    }

    /// The id prefixes of machines that are not Cloud machines, from the types that make their ids.
    private static let nonCloudIDPrefixes = [SSHHost.machineIDPrefix, ServerReach.machineIDPrefix]

    let local: DaemonService
    /// Cloud machines in sidebar order (newest last).
    private(set) var cloud: [CloudMachineSession] = []
    /// The account's Cloud machine cap from the last `/api/vm` list (nil
    /// before one, or when the list carried none). Never inferred from `cloud`.
    var cloudLimits: CloudMachineLimits?
    /// SSH machines in the order they were added.
    private(set) var ssh: [SSHMachineSession] = []
    /// Paired servers whose Chief brain session the app shows (`ServerReachService`).
    private(set) var servers: [ServerMachineSession] = []

    /// Whether an administrator turned off a feature (`DisabledFeatures`):
    /// a Cloud machine is not reachable with `cloud` off, an SSH machine
    /// not with `remoteHosts` off, so no path opens work on it.
    @ObservationIgnored var isFeatureDisabled: (ActionFeature) -> Bool = { _ in false }
    /// A machine left the registry (forgotten, deleted, unpaired): its
    /// connections that live outside its session close (cx-2cob slice 2:
    /// the forwarding connection and the browser runtimes on it).
    @ObservationIgnored var onDaemonRemoved: (@MainActor (DaemonService) -> Void)?

    /// Every machine's daemon update state (the app's ``DaemonUpdates/board``; a test's registry has its own).
    let updates: DaemonUpdateBoard

    init(local: DaemonService, updates: DaemonUpdateBoard = DaemonUpdateBoard()) {
        self.local = local
        self.updates = updates
    }

    /// Where a create in a space goes (`creation(in:)`).
    enum SpaceCreation {
        /// The space has no default session: this Mac.
        case mac
        /// The space's default session's daemon.
        case machine(DaemonService)
        /// The space names a session no listed machine serves (the machine list has not come yet, the account
        /// signed out, or the machine was deleted): the create is refused, never made on the Mac instead.
        case unresolved

        /// The machine's daemon, nil for the other cases.
        var daemon: DaemonService? { if case let .machine(daemon) = self { daemon } else { nil } }
    }

    /// Local first, then Cloud machines, then SSH machines, then servers.
    var daemons: [DaemonService] { [local] + remoteDaemons }

    /// Every daemon that is not the local one.
    var remoteDaemons: [DaemonService] { cloud.map(\.daemon) + ssh.map(\.daemon) + servers.map(\.daemon) }

    func session(_ machineID: String) -> CloudMachineSession? {
        cloud.first { $0.machineID == machineID }
    }

    func sshSession(_ machineID: String) -> SSHMachineSession? {
        ssh.first { $0.machineID == machineID }
    }

    func server(_ machineID: String) -> ServerMachineSession? {
        servers.first { $0.machineID == machineID }
    }

    /// The machine's daemon even while its feature is turned off (its
    /// endpoint refuses); for routing that must not fall back to this Mac.
    func anyDaemon(machine machineID: String) -> DaemonService? {
        machineID == Self.localID ? local : session(machineID)?.daemon ?? sshSession(machineID)?.daemon ?? server(machineID)?.daemon
    }

    func daemon(machine machineID: String) -> DaemonService? {
        if machineID == Self.localID { return local }
        if let cloud = session(machineID) { return isFeatureDisabled(.cloud) ? nil : cloud.daemon }
        // A server's session rides the remote-hosts carrier.
        return isFeatureDisabled(.remoteHosts) ? nil : sshSession(machineID)?.daemon ?? server(machineID)?.daemon
    }

    /// The empty-workspace repair of `machineID` (the local one for local
    /// or an unknown machine).
    func emptyWorkspaceRepair(_ machineID: String?, local fallback: EmptyWorkspaceRepair) -> EmptyWorkspaceRepair {
        guard let machineID else { return fallback }
        return session(machineID)?.emptyWorkspaces ?? sshSession(machineID)?.emptyWorkspaces ?? server(machineID)?.emptyWorkspaces ?? fallback
    }

    /// The short name on a remote machine's tabs: the host (never the
    /// session), or the Cloud machine's title.
    func machineBadge(_ machineID: String) -> String? {
        session(machineID)?.machine.title ?? sshSession(machineID)?.host.destination.displayName ?? server(machineID)?.name
    }

    /// The machine name on the tabs of `machineID`'s tree: nil for a tree that runs on this
    /// Mac (2026-10-20: every Chief subagent tab wore "Chief"). The Chief owner daemon and a
    /// server that is this Mac are reached at a Unix socket here; their tabs run on this Mac.
    func tabBadge(_ machineID: String) -> String? {
        if let server = server(machineID), case .unix = server.reach.route { return nil }
        return machineBadge(machineID)
    }

    /// The sidebar name of a remote machine, nil for local.
    func machineName(_ machineID: String) -> String? {
        session(machineID)?.machine.title ?? sshSession(machineID)?.host.label ?? server(machineID)?.name
    }

    /// The name a tab's machine badge takes its color from (`TabItem.machineName`): the sidebar
    /// name of `machineID` when `badge` is that machine's short name (an SSH host's badge shows
    /// its destination, the sidebar its label), so the tab wears its rows' MachineColor. Nil for
    /// any other badge (a "this Mac" chip) or a machine not known here: the badge's own text.
    func tabColorName(_ machineID: String?, badge: String?) -> String? {
        guard let machineID, let badge, badge == machineBadge(machineID) else { return nil }
        return machineName(machineID)
    }

    /// What `daemon` can do for the app. A remote daemon never needs the
    /// home-only capabilities, nor, once the local daemon keeps personal
    /// state (`profiles-v1`), workspace groups and saved tab groups.
    /// `terminal-reaper-active-v1` says how a daemon was started (with a
    /// reap grace), not what its build serves: a remote daemon that the SSH
    /// bootstrap starts never has it, and tab close handles both cases, so
    /// its absence is not "update this machine" (cx-z0uk: a daemon installed
    /// from the app's own tree still read as limited).
    func compatibility(of daemon: DaemonService) -> DaemonCompatibility? {
        guard !daemon.isLocal else { return daemon.compatibility }
        var notNeeded = Set(DaemonCapability.homeOnly)
        notNeeded.insert(DaemonCapability.terminalReaperActive.rawValue)
        if local.supports(DaemonCapability.profiles.rawValue) { notNeeded.formUnion(DaemonCapability.personalOnHome) }
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
    func daemon(forWorkspace id: String) -> DaemonService? { workspace(id: id)?.1 }

    /// O(1) per daemon (`DaemonStore.workspace(id:)`).
    func workspace(id: String) -> (WorkspaceModel, DaemonService)? {
        if let workspace = local.store.workspace(id: id) { return (workspace, local) } // no daemon list for the common case
        return remoteDaemons.lazy.compactMap { daemon in daemon.store.workspace(id: id).map { ($0, daemon) } }.first
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

    /// The daemon of agent tab `tab`, whose record names a host other than this Mac (its chat
    /// runs on another machine): the remote daemon whose tree lists it. Refused, never this Mac's
    /// daemon in its place (hq-84, cx-cmok), when this Mac's tree lists it, or when the record
    /// names a store (`registry:<id>`) other than the one listing it.
    func agentDaemon(forTab tab: TabModel) throws(MachineRoutingRefusal) -> DaemonService {
        let daemon = daemon(forTab: tab)
        let host = tab.agentSession?.host ?? ""
        guard !daemon.isLocal else { throw MachineRoutingRefusal(host: host, machineID: daemon.machineID) }
        if host.hasPrefix(Self.registryHostPrefix) {
            let named = host.dropFirst(Self.registryHostPrefix.count).lowercased()
            guard let own = daemon.store.registryID ?? daemon.identity?.sessionID, own.lowercased() == named else {
                throw MachineRoutingRefusal(host: host, machineID: daemon.machineID)
            }
        }
        return daemon
    }

    /// An agent tab record's `host` naming a machine's store (cmux-tui `store_host`).
    nonisolated static let registryHostPrefix = "registry:"

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
        let removed = cloud.remove(at: index)
        onDaemonRemoved?(removed.daemon)
        return removed
    }

    // MARK: SSH sessions (SSHService only)

    func add(_ session: SSHMachineSession) {
        guard sshSession(session.machineID) == nil else { return }
        ssh.append(session)
    }

    func removeSSH(_ machineID: String) -> SSHMachineSession? {
        guard let index = ssh.firstIndex(where: { $0.machineID == machineID }) else { return nil }
        let removed = ssh.remove(at: index)
        onDaemonRemoved?(removed.daemon)
        return removed
    }

    // MARK: Servers (ServerReachService only)

    func add(_ session: ServerMachineSession) {
        guard server(session.machineID) == nil else { return }
        servers.append(session)
    }

    func removeServer(_ machineID: String) -> ServerMachineSession? {
        guard let index = servers.firstIndex(where: { $0.machineID == machineID }) else { return nil }
        let removed = servers.remove(at: index)
        onDaemonRemoved?(removed.daemon)
        return removed
    }
}

/// An agent tab whose record names a machine other than the daemon whose tree lists it: its chat
/// is not run, read or shown through that daemon (``MachineRegistry/agentDaemon(forTab:)``).
nonisolated struct MachineRoutingRefusal: Error, Equatable {
    /// The tab record's host.
    let host: String
    /// The machine whose tree lists the tab.
    let machineID: String
}

// Where a space's new workspaces go (plans/cmux-next/data-model.md 4 rule 3): a space with a default session
// creates there. A Cloud space follows one Cloud machine's session and creates on it, so the window shows that
// machine's own workspaces, terminals and browser tabs. The session is the stable key; the machine is found
// through the daemon that serves it now, else through the home registry's record of how to reach it, so a
// paused machine (no daemon identity yet this launch) still resolves to its session and wakes.
extension MachineRegistry {
    func creation(in profile: ProfileID) -> SpaceCreation {
        guard let session = local.store.profile(profile)?.defaultSessionID else { return .mac }
        guard let daemon = daemon(forSession: session) else { return .unresolved }
        return daemon.isLocal ? .mac : .machine(daemon)
    }

    /// The daemon serving `sessionID` now, else the machine the home registry recorded for it.
    func daemon(forSession sessionID: String) -> DaemonService? {
        if let live = daemon(session: sessionID) { return live }
        let record = local.store.personal.session(sessionID.lowercased()) ?? local.store.personal.session(sessionID)
        return Self.machineID(transport: record?.transport).flatMap(anyDaemon(machine:))
    }

    /// The Cloud machine behind `daemon`, if it is one.
    func cloudSession(of daemon: DaemonService) -> CloudMachineSession? {
        daemon.isLocal ? nil : session(daemon.machineID)
    }
}
