import CmuxControlSocket
import CmuxRemoteWorkspace
import Foundation

extension TerminalController {
    private struct RemoteRelayAuthorizationSnapshot: Sendable {
        let ownerWorkspaceID: UUID
        let relayTokenHex: String
        let surfaceIDs: Set<UUID>
    }

    /// Result returned by the single socket-ingress relay authorization gate.
    /// `errorResponse` is already encoded so both socket execution lanes return
    /// the same envelope without dispatching an unauthorized request.
    struct RemoteRelayAuthorizationResult: Sendable {
        let request: ControlRequest
        let errorResponse: String?
    }

    /// Authorizes relay metadata before execution-policy routing.  Ordinary
    /// local socket requests have no generic relay MAC and pass through
    /// unchanged; a request carrying relay provenance must prove the live
    /// owner workspace's current token and remain inside the positive method
    /// and selector allow-list below.
    nonisolated func authorizeRemoteRelayRequest(
        _ request: ControlRequest
    ) -> RemoteRelayAuthorizationResult {
        let foundationParams = request.params.mapValues(\.foundationObject)
        let hasRequestMAC = foundationParams[WorkspaceRemoteRelayCommandRewriter.requestAuthenticationCodeKey] != nil
        let hasOwnerProvenance = foundationParams[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey] != nil
        guard hasRequestMAC || hasOwnerProvenance else {
            return RemoteRelayAuthorizationResult(request: request, errorResponse: nil)
        }

        guard let ownerRaw = foundationParams[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey] as? String,
              let ownerWorkspaceID = UUID(uuidString: ownerRaw) else {
            return deniedRemoteRelayRequest(
                request,
                code: "remote_relay_authentication_required",
                message: "Relay request is missing a valid owner workspace"
            )
        }
        guard hasRequestMAC else {
            return deniedRemoteRelayRequest(
                request,
                code: "remote_relay_authentication_required",
                message: "Relay request authentication is missing"
            )
        }

        // Ownership, token rotation, and panel moves are @MainActor state.
        // Snapshot them on the main actor before the socket policy chooses a
        // worker lane; this is deliberately one security-boundary hop for
        // authenticated relay traffic, while ordinary local/telemetry
        // requests still stay on their existing off-main paths.
        let snapshot: RemoteRelayAuthorizationSnapshot? = v2MainSync(commandKey: request.method) {
            guard let workspace = AppDelegate.shared?.workspaceFor(tabId: ownerWorkspaceID),
                  let configuration = workspace.remoteConfiguration,
                  configuration.ownerWorkspaceID == ownerWorkspaceID,
                  let relayToken = configuration.relayToken,
                  !relayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            // The pane tree's reverse index is authoritative for ordinary
            // surfaces and can be enumerated directly.  Remote tmux mirrors
            // own projected surfaces outside that index, so include their
            // published topology in the same linear snapshot.
            var surfaceIDs = Set(workspace.panels.keys)
            surfaceIDs.formUnion(workspace.surfaceIdToPanelId.keys.map(\.uuid))
            for mirror in workspace.remoteTmuxWindowMirrors.values {
                surfaceIDs.formUnion(mirror.surfaceIDsInLayoutOrder)
            }
            if let sessionMirror = workspace.remoteTmuxSessionMirror {
                surfaceIDs.formUnion(sessionMirror.controlPaneLocations().map(\.pane.panel.id))
            }
            return RemoteRelayAuthorizationSnapshot(
                ownerWorkspaceID: ownerWorkspaceID,
                relayTokenHex: relayToken,
                surfaceIDs: surfaceIDs
            )
        }
        guard let snapshot else {
            return deniedRemoteRelayRequest(
                request,
                code: "remote_relay_workspace_denied",
                message: "Relay owner workspace is not active"
            )
        }
        guard WorkspaceRemoteRelayCommandRewriter.authenticatesRemoteRelayRequest(
            id: request.id?.foundationObject,
            method: request.method,
            params: foundationParams,
            remoteRelayTokenHex: snapshot.relayTokenHex
        ) else {
            return deniedRemoteRelayRequest(
                request,
                code: "remote_relay_authentication_failed",
                message: "Relay request authentication failed"
            )
        }
        switch RemoteRelayAuthorizationPolicy().validate(
            method: request.method,
            parameters: foundationParams,
            ownerWorkspaceID: snapshot.ownerWorkspaceID,
            surfaceIDs: snapshot.surfaceIDs
        ) {
        case .allowed:
            break
        case .denied(let code, let message):
            return deniedRemoteRelayRequest(
                request,
                code: code,
                message: message
            )
        }

        var sanitizedParams = request.params
        sanitizedParams.removeValue(forKey: WorkspaceRemoteRelayCommandRewriter.requestAuthenticationCodeKey)
        let sanitizedRequest = ControlRequest(
            id: request.id,
            method: request.method,
            params: sanitizedParams
        )
        return RemoteRelayAuthorizationResult(
            request: sanitizedRequest,
            errorResponse: nil
        )
    }

    private nonisolated func deniedRemoteRelayRequest(
        _ request: ControlRequest,
        code: String,
        message: String
    ) -> RemoteRelayAuthorizationResult {
        RemoteRelayAuthorizationResult(
            request: request,
            errorResponse: ControlResponseEncoder().error(
                id: request.id,
                code: code,
                message: message
            )
        )
    }

}
