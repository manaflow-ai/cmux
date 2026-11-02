import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextServer
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation

/// New Remote Group (remote-groups-DESIGN.md slice 4): one action from a host name to a remote group.
/// It connects the host through `SSHService` as `remote.connect` does (an existing machine for the same
/// host is reused, never added twice), shows its first workspace, and marks its machine section a remote
/// group on the sidebar document once its daemon names its session, so the section keeps its header,
/// with the host's name and status, in one list. New workspaces in it run on the host.
@MainActor
enum RemoteGroupHandlers {
    static func shouldContinueMarking(status: SSHConnectionMachine.Status) -> Bool {
        status != .offline
    }

    /// A focus request makes an automated run interactive for this action even
    /// while the registry is capturing its refusal output.
    static func shouldOfferInteractiveFlow(_ invocation: ActionInvocation) -> Bool {
        invocation.allowsViewChange
    }

    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let ssh = context.services.ssh
        CloudHandlers.bind("remote.newGroup", registry, reason: { ssh.unavailableReason }) { invocation in
            let interactive = shouldOfferInteractiveFlow(invocation)
            // `cmux workspace group create --remote HOST --name N` names the group's header.
            let name = invocation["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let make = { (text: String) throws in
                let session = try ssh.connect(destination: text, session: nil, offerInstall: interactive, byPerson: invocation.isPersonsRequest)
                markWhenNamed(session, name: name, doc: context.services.sidebarDoc)
                if interactive { RemoteHandlers.showWhenConnected(session, context) }
            }
            if let text = invocation["destination"]?.stringValue { return try make(text) }
            // The host as a Cmd-Shift-P step; Return runs this again with it.
            registry.ask("remote.newGroup", invocation, ActionArgumentAsk(argument: "destination"))
        }
        // The host step lists connected machines, Tailscale peers and ~/.ssh/config aliases (slice E).
        let cli = (try? DaemonLauncher.resolveBinary(bundle: .main, environment: ProcessInfo.processInfo.environment)).map { HostCLI(binary: $0, environment: SSHService.environment) }
        let work = context.services.work, home = FileManager.default.homeDirectoryForCurrentUser
        let hosts = RemoteHostCatalog(connected: { context.services.machines.ssh.map(\.host.destination.description) }, peers: { await cli?.candidates(probe: false).flatMap { try? HostCandidate.parseList($0) } }, aliases: { (try? await work.run(.bestEffort, mayBlock: .files) { SSHConfigHosts.aliases(in: home.appending(path: ".ssh"), home: home) { try? String(blockingContentsOfFile: $0, encoding: .utf8) } }) ?? [] })
        // task-owner: one warm-up read so the first ask lists every host; bounded by the CLI's deadline.
        Task(priority: WorkPriority.bestEffort.taskPriority) { await hosts.reload() }
        let otherSuggestions = registry.argumentSuggestions
        registry.argumentSuggestions = { $0 == ActionSuggestions.remoteHosts ? hosts.choices().map { ActionEnumCase(value: $0.destination, title: $0.title) } : otherSuggestions?($0) ?? [] }
        // Back to rows of the one list; the host stays connected and its workspaces stay.
        registry.bind("remote.removeGroup", run: { invocation in
            guard let session = session(invocation, context) else {
                throw ActionFailure.invalidTarget(WorkspaceVerbStrings.noMachine)
            }
            guard let store = context.services.sidebarDoc.activeStore else {
                throw ActionFailure.invalidTarget(WorkspaceVerbStrings.subgroupNeedsDocument)
            }
            let ops = try removalOps(session: session, records: store.records)
            do throws(SidebarDocSendRefusal) {
                try store.sendChecked(ops: ops, title: RemoteStrings.newGroupTitle)
            } catch {
                throw ActionFailure.invalidTarget(error.message)
            }
        })
        // Reconnect on a paired server's or a Cloud machine's header (an SSH host has remote.reconnect).
        registry.bind("machine.reconnect", run: { invocation in
            guard let machine = invocation.target?.id ?? invocation["machine"]?.stringValue else {
                throw ActionFailure.invalidTarget(WorkspaceVerbStrings.noMachine)
            }
            let machines = context.services.machines
            switch route(machine, machines) {
            case .wakeServer: machines.server(machine)?.wake()
            case .retryCloud: machines.session(machine)?.retry()
            case .ssh: _ = registry.perform("remote.reconnect", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: machine), origin: invocation.origin))
            case .none: throw ActionFailure.invalidTarget(WorkspaceVerbStrings.noMachine)
            }
        })
        ActionTargetVisibility.hide("machine.reconnect", in: registry) { invocation in
            guard let machine = invocation.target?.id else { return true }
            return !route(machine, context.services.machines).showsSharedRow
        }
        // Only a remote group's header offers it.
        ActionTargetVisibility.hide("remote.removeGroup", in: registry) { invocation in
            guard let session = session(invocation, context), let store = context.services.sidebarDoc.store else { return true }
            return store.records.sections["sec_m_\(session)"]?.hostGroup != true
        }
    }

    /// The ops that turn daemon session `session`'s remote group back into rows of the one list.
    /// Throws when its machine section is not a remote group: nothing to remove is not a success.
    static func removalOps(session: String, records: SidebarDocRecords) throws(ActionFailure) -> [[String: Any]] {
        let ops = SidebarDocHostGroupPlan(session: session, records: records, on: false).ops
        guard !ops.isEmpty else { throw ActionFailure.invalidTarget(RemoteStrings.notARemoteGroup) }
        return ops
    }

    private static func route(_ machine: String, _ machines: MachineRegistry) -> MachineReconnectRoute {
        MachineReconnectRoute(isLocal: machine == MachineRegistry.localID, isSSH: machines.sshSession(machine) != nil,
                              isServer: machines.server(machine) != nil, isCloud: machines.session(machine) != nil)
    }

    /// The daemon session of the invocation's machine (target or `machine` argument).
    private static func session(_ invocation: ActionInvocation, _ context: AppActionContext) -> String? {
        guard let machine = invocation.target?.id ?? invocation["machine"]?.stringValue else { return nil }
        return context.services.machines.anyDaemon(machine: machine)?.store.registryID
    }

    /// Marks `session`'s machine section a remote group once its daemon names its session; gives up
    /// when the machine stops connecting.
    static func markWhenNamed(_ session: SSHMachineSession, name: String? = nil, doc: SidebarDocument) {
        let daemon = session.daemon, groupName = name
        // task-owner: ends when the daemon names its session or the machine stops connecting
        Task { @MainActor in
            for await (name, status) in ObservationStream({ (daemon.store.registryID, session.linkStatus) }) {
                if let registryID = name {
                    mark(session: registryID, name: groupName, doc: doc)
                    return
                }
                if Self.shouldContinueMarking(status: status) { continue }
                return
            }
        }
    }

    /// Makes the machine section of daemon session `session` a remote group; nothing for an unnamed session.
    /// New Remote Group, New Cloud Workspace and a new Cloud machine call it: a Cloud machine's workspaces sit in one group.
    /// `doc`: the app's own sidebar document.
    static func mark(session: String?, name: String? = nil, doc: SidebarDocument) {
        if let session { doc.activeStore?.markHostGroup(session: session, title: RemoteStrings.newGroupTitle, name: name) }
    }
}
