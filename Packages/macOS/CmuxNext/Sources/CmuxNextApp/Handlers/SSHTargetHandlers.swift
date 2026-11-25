import CmuxNextActions
import CmuxNextDaemon

/// The SSH rows of a workspace and a tab: Reconnect Workspace, Disconnect
/// Workspace, Copy SSH Error and Disconnect SSH Tab. Each acts on the SSH
/// machine the workspace or the tab's terminal runs on, as that machine's
/// own row does (`RemoteHandlers`): a disconnect keeps the machine, so a
/// Reconnect brings it back (classic `disconnectRemoteConnection(clearConfiguration: false)`).
/// A workspace or tab of this Mac, a Cloud machine or a server has no SSH
/// connection: its menu leaves the rows out, and the palette and CLI are refused.
enum SSHTargetHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        let ssh = context.services.ssh
        let available: @MainActor () -> String? = { ssh.unavailableReason }
        CloudHandlers.bind("reconnectWorkspace", registry, reason: available) { ssh.reconnect(try workspaceMachine($0, context), byPerson: $0.isPersonsRequest) }
        CloudHandlers.bind("disconnectWorkspace", registry, reason: available) { ssh.disconnect(try workspaceMachine($0, context)) }
        CloudHandlers.bind("copyWorkspaceSSHError", registry, reason: available) { invocation in
            let session = try workspaceMachine(invocation, context)
            guard let error = RemoteStrings.sshError(session) else { throw ActionFailure(message: RemoteStrings.noSSHError(session.host.label)) }
            context.copy(error)
        }
        CloudHandlers.bind("disconnectRemoteTab", registry, reason: available) { invocation in
            guard let (tab, _) = context.daemonTab(invocation) else { return }
            guard let session = tabMachine(tab, context.services) else { throw ActionFailure(message: RemoteStrings.tabNotOnSSHMachine) }
            ssh.disconnect(session)
        }
        for id: ActionID in ["reconnectWorkspace", "disconnectWorkspace", "copyWorkspaceSSHError"] {
            ActionTargetVisibility.hide(id, in: registry) { invocation in
                guard let target = invocation.target, target.kind == .workspace else { return false }
                return workspaceMachine(target.id, context.services) == nil
            }
        }
        ActionTargetVisibility.hide("disconnectRemoteTab", in: registry) { invocation in
            guard let target = invocation.target, target.kind == .tab else { return false }
            return context.targetTab(target.id, invocation).flatMap { tabMachine($0.0, context.services) } == nil
        }
    }

    /// The SSH machine of the targeted or active workspace.
    private static func workspaceMachine(_ invocation: ActionInvocation, _ context: AppActionContext) throws -> SSHMachineSession {
        let (workspace, _) = try context.workspace(invocation)
        guard let session = workspaceMachine(workspace.id, context.services) else { throw ActionFailure(message: RemoteStrings.workspaceNotOnSSHMachine) }
        return session
    }

    private static func workspaceMachine(_ id: String, _ services: AppServices) -> SSHMachineSession? {
        services.machines.daemon(forWorkspace: id).flatMap { services.machines.sshSession($0.machineID) }
    }

    /// The SSH machine `tab`'s terminal runs on: a remote-terminal tab's
    /// session (a mixed workspace), else the machine whose tree holds it.
    private static func tabMachine(_ tab: TabModel, _ services: AppServices) -> SSHMachineSession? {
        let daemon = tab.remote.flatMap { services.machines.daemon(session: $0.sessionID) } ?? services.machines.daemon(forTab: tab)
        return services.machines.sshSession(daemon.machineID)
    }
}
