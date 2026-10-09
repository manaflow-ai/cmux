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
        if params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey] != nil {
            guard let connectionID = v2UUID(params, WorkspaceRemoteRelayCommandRewriter.connectionIDKey),
                  authenticatedWorkspace.activeRemoteSessionControllerID == connectionID else {
                return false
            }
            // `liveRelayAgentDeliveryTarget` already resolved this target from
            // a fresh TTY report whose origin matches the authenticated owner.
            // A Dock legitimately returns its presentation workspace ID rather
            // than the relay-owner workspace ID; requiring equality here would
            // reject valid remote Dock delivery. The owner/connection check
            // above and the resolver's provenance filter remain authoritative.
        }
        return true
    }
}
