import CmuxNextActions
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextSidebar

/// New Remote Group (remote-groups-DESIGN.md slice 4): one action from a host name to a remote group.
/// It connects the host through `SSHService` as `remote.connect` does (an existing machine for the same
/// host is reused, never added twice), shows its first workspace, and marks its machine section a remote
/// group on the sidebar document once its daemon names its session, so the section keeps its header,
/// with the host's name and status, in one list. New workspaces in it run on the host.
@MainActor
enum RemoteGroupHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let ssh = context.services.ssh
        CloudHandlers.bind("remote.newGroup", registry, reason: { ssh.unavailableReason }) { invocation in
            let interactive = !registry.isCapturingRefusal
            let make = { (text: String) throws in
                let session = try ssh.connect(destination: text, session: nil, offerInstall: interactive)
                markWhenNamed(session)
                if interactive { RemoteHandlers.showWhenConnected(session, context) }
            }
            if let text = invocation["destination"]?.stringValue { return try make(text) }
            // The host as a Cmd-Shift-P step; Return runs this again with it.
            registry.ask("remote.newGroup", invocation, ActionArgumentAsk(argument: "destination"))
        }
        // Back to rows of the one list; the host stays connected and its workspaces stay.
        registry.bind("remote.removeGroup", run: { invocation in
            guard let session = session(invocation, context) else {
                throw ActionFailure.invalidTarget(WorkspaceVerbStrings.noMachine)
            }
            guard let store = SidebarDocStore.current, SidebarDocWiring.isActive else {
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
            case .ssh: _ = registry.perform("remote.reconnect", invocation: ActionInvocation(target: ActionTargetRef(kind: .machine, id: machine)))
            case .none: throw ActionFailure.invalidTarget(WorkspaceVerbStrings.noMachine)
            }
        })
        ActionTargetVisibility.hide("machine.reconnect", in: registry) { invocation in
            guard let machine = invocation.target?.id else { return true }
            return !route(machine, context.services.machines).showsSharedRow
        }
        // Only a remote group's header offers it.
        ActionTargetVisibility.hide("remote.removeGroup", in: registry) { invocation in
            guard let session = session(invocation, context), let store = SidebarDocStore.current else { return true }
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
    static func markWhenNamed(_ session: SSHMachineSession) {
        let daemon = session.daemon
        // task-owner: ends when the daemon names its session or the machine stops connecting
        Task { @MainActor in
            for await (name, status) in ObservationStream({ (daemon.store.registryID, session.linkStatus) }) {
                if let name {
                    mark(session: name)
                    return
                }
                switch status {
                case .connecting, .connected, .reconnecting, .installing, .needsInstall, .unreachable, .failed: continue
                case .offline, .authFailed, .hostKeyUntrusted, .installFailed: return
                }
            }
        }
    }

    /// Makes the machine section of daemon session `session` a remote group; nothing for an unnamed session.
    /// New Remote Group, New Cloud Workspace and a new Cloud machine call it: a Cloud machine's workspaces sit in one group.
    static func mark(session: String?) {
        if let session, SidebarDocWiring.isActive { SidebarDocStore.current?.markHostGroup(session: session, title: RemoteStrings.newGroupTitle) }
    }
}
