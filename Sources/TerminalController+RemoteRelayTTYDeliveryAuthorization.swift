import CmuxControlSocket
import Foundation

/// Enforces live relay ownership before returning a reported TTY target.
extension TerminalController {
    @MainActor
    func remoteRelayTTYDeliveryTargetIsCurrent(
        _ target: AgentDeliveryTargetCandidate,
        authenticatedWorkspace: Workspace,
        params: [String: Any]
    ) -> Bool {
        // Socket ingress always stamps and authenticates the live connection
        // generation before this handler runs. Direct in-process callers omit
        // relay metadata and retain the existing moved-surface behavior.
        if let connectionID = v2UUID(params, WorkspaceRemoteRelayCommandRewriter.connectionIDKey),
           authenticatedWorkspace.activeRemoteSessionControllerID != connectionID {
            return false
        }
        return params[WorkspaceRemoteRelayCommandRewriter.connectionIDKey] == nil
            || target.workspaceId == authenticatedWorkspace.id
    }
}
