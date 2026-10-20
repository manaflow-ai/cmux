import CmuxNextActions
import CmuxNextDaemon

/// Reconnect Workspace, Disconnect Workspace and Copy SSH Error on a
/// workspace row, and Disconnect SSH Tab on a tab: each acts on the SSH
/// machine that the workspace or the tab's terminal runs on, through the
/// same `SSHService` calls as the machine header's Reconnect, Disconnect and
/// Copy SSH Error (`RemoteHandlers`). A workspace never mixes machines, so
/// its machine is the daemon whose tree holds it; a remote-terminal tab's
/// machine is the session its terminal runs on. The machine link is shared:
/// disconnecting one workspace or tab disconnects every workspace on that
/// machine, and its programs keep running there.
enum RemoteWorkspaceHandlers {
    static let workspaceActions: Set<ActionID> = ["reconnectWorkspace", "disconnectWorkspace", "copyWorkspaceSSHError"]
    static let tabAction: ActionID = "disconnectRemoteTab"

    static func bind(into registry: ActionRegistry, context ctx: AppActionContext) {
        let ssh = ctx.services.ssh
        registry.bind("reconnectWorkspace", invoke: { invocation in
            guard let session = workspaceMachine(invocation, ctx) else { return }
            ssh.reconnect(session)
        })
        registry.bind("disconnectWorkspace", invoke: { invocation in
            guard let session = workspaceMachine(invocation, ctx) else { return }
            ssh.disconnect(session)
        })
        registry.bind("copyWorkspaceSSHError", invoke: { invocation in
            guard let session = workspaceMachine(invocation, ctx) else { return }
            guard let error = RemoteStrings.sshError(session) else { return ctx.refuse(RemoteStrings.noSSHError(session.host.label)) }
            ctx.copy(error)
        })
        registry.bind(tabAction, invoke: { invocation in
            guard let (tab, _) = ctx.daemonTab(invocation) else { return }
            guard let session = machine(of: tab, ctx.services.machines) else { return ctx.refuse(RemoteStrings.tabNotSSH) }
            ssh.disconnect(session)
        })
        // A row on this Mac's workspace or tab reads disabled with the reason (menus, palette, CLI).
        for id in workspaceActions {
            ActionTargetReasons.set(id, in: registry) { invocation in
                guard let target = invocation.target, target.kind == .workspace else { return nil }
                return ctx.services.machines.workspace(id: target.id).flatMap { machine(ofDaemon: $0.1, ctx.services.machines) } == nil
                    ? RemoteStrings.workspaceNotSSH : nil
            }
        }
    }

    /// The SSH machine of the targeted (or shown) workspace; refuses when it is on another machine.
    private static func workspaceMachine(_ invocation: ActionInvocation, _ ctx: AppActionContext) -> SSHMachineSession? {
        guard let workspace = ctx.scope(invocation).workspace else { return nil }
        let machines = ctx.services.machines
        guard let daemon = machines.daemon(forWorkspace: workspace.id), let session = machine(ofDaemon: daemon, machines) else {
            return ctx.refuse(RemoteStrings.workspaceNotSSH)
        }
        return session
    }

    private static func machine(ofDaemon daemon: DaemonService, _ machines: MachineRegistry) -> SSHMachineSession? {
        daemon.isLocal ? nil : machines.sshSession(daemon.machineID)
    }

    /// The SSH machine `tab`'s terminal runs on: a remote-terminal tab's
    /// session, else the machine whose tree holds the tab.
    static func machine(of tab: TabModel, _ machines: MachineRegistry) -> SSHMachineSession? {
        if tab.kind == .remoteTerminal {
            return tab.remote.flatMap { machines.daemon(session: $0.sessionID) }.flatMap { machine(ofDaemon: $0, machines) }
        }
        return machine(ofDaemon: machines.daemon(forTab: tab), machines)
    }

    /// Workspace row menu rows to hide: the SSH rows unless the workspace is on an SSH machine.
    static func hiddenWorkspaceMenuItems(_ workspaceID: String, _ machines: MachineRegistry) -> Set<ActionID> {
        machines.workspace(id: workspaceID).flatMap { machine(ofDaemon: $0.1, machines) } == nil ? workspaceActions : []
    }

    /// Tab menu rows to hide: Disconnect SSH Tab unless the tab runs on an SSH machine.
    static func hiddenTabMenuItems(_ tab: TabModel?, _ machines: MachineRegistry) -> Set<ActionID> {
        tab.flatMap { machine(of: $0, machines) } == nil ? [tabAction] : []
    }
}
