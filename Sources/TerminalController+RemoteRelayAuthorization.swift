import CmuxControlSocket
import CmuxRemoteWorkspace
import Foundation

extension TerminalController {
    /// Resolve product text in the app while keeping the package policy pure.
    private nonisolated func remoteRelayAuthorizationPolicy() -> RemoteRelayAuthorizationPolicy {
        RemoteRelayAuthorizationPolicy(invalidSelectorMessage: String(
            localized: "socket.remoteRelay.invalidSelector", defaultValue: "Relay selector is invalid"
        ))
    }

    private nonisolated var remoteRelayAuthenticationFailedMessage: String {
        String(localized: "socket.remoteRelay.authenticationFailed", defaultValue: "Relay request authentication failed")
    }

    private struct RemoteRelayAuthorizationSnapshot: Sendable {
        let ownerWorkspaceID: UUID
        let relayTokenHex: String
        let connectionID: UUID
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
        authorizeRemoteRelayRequest(request) { ownerWorkspaceID in
            self.v2MainSync(commandKey: request.method) {
                self.remoteRelayAuthorizationSnapshot(ownerWorkspaceID: ownerWorkspaceID)
            }
        }
    }

    /// Socket connections await the topology snapshot instead of blocking a worker.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func authorizeRemoteRelayRequestAsync(
        _ request: ControlRequest
    ) async -> RemoteRelayAuthorizationResult {
        let snapshot: RemoteRelayAuthorizationSnapshot?
        if case .string(let ownerRaw)? = request.params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey],
           let ownerWorkspaceID = UUID(uuidString: ownerRaw),
           request.params[WorkspaceRemoteRelayCommandRewriter.requestAuthenticationCodeKey] != nil {
            snapshot = await v2MainAsync {
                self.remoteRelayAuthorizationSnapshot(ownerWorkspaceID: ownerWorkspaceID)
            }
        } else {
            snapshot = nil
        }
        return authorizeRemoteRelayRequest(request) { _ in snapshot }
    }

    private nonisolated func authorizeRemoteRelayRequest(
        _ request: ControlRequest,
        resolveSnapshot: (UUID) -> RemoteRelayAuthorizationSnapshot?
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

        let snapshot = resolveSnapshot(ownerWorkspaceID)
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
                message: remoteRelayAuthenticationFailedMessage
            )
        }
        guard foundationParams[WorkspaceRemoteRelayCommandRewriter.connectionIDKey] as? String
                == snapshot.connectionID.uuidString else {
            return deniedRemoteRelayRequest(request, code: "remote_relay_authentication_failed",
                message: remoteRelayAuthenticationFailedMessage)
        }
        switch remoteRelayAuthorizationPolicy().validate(
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

    /// Captures token and topology together at the authority that owns both.
    private func remoteRelayAuthorizationSnapshot(
        ownerWorkspaceID: UUID
    ) -> RemoteRelayAuthorizationSnapshot? {
        guard let workspace = AppDelegate.shared?.workspaceFor(tabId: ownerWorkspaceID),
              let configuration = workspace.remoteConfiguration,
              configuration.ownerWorkspaceID == ownerWorkspaceID,
              let connectionID = workspace.activeRemoteSessionControllerID,
              let relayToken = configuration.relayToken,
              !relayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        // The pane tree's reverse index is authoritative for ordinary
        // surfaces and can be enumerated directly.  Remote tmux mirrors
        // own projected surfaces outside that index, so include their
        // published topology in the same linear snapshot.
        // Only live remote terminal identities are relay-owned.  A remote
        // workspace can also contain local/browser panels created by the user;
        // container membership alone must never authorize local input, shell
        // creation, or scrollback reads for those panels.
        // A moved remote terminal may remain in the destination's remote
        // lifecycle set when both workspaces share a relay namespace. Its
        // launch provenance is still owned by the original workspace, so it
        // must not enter the destination relay's authorized surface set.
        var surfaceIDs = workspace.activeRemoteTerminalSurfaceIds.filter {
            workspace.surfaceRegistry.remoteTTYReportOriginWorkspaceIDs[$0] == ownerWorkspaceID
        }
        for mirror in workspace.remoteTmuxWindowMirrors.values {
            surfaceIDs.formUnion(mirror.surfaceIDsInLayoutOrder)
        }
        if let sessionMirror = workspace.remoteTmuxSessionMirror {
            surfaceIDs.formUnion(sessionMirror.controlPaneLocations().map(\.pane.panel.id))
        }
        return RemoteRelayAuthorizationSnapshot(
            ownerWorkspaceID: ownerWorkspaceID,
            relayTokenHex: relayToken,
            connectionID: connectionID,
            surfaceIDs: surfaceIDs
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

    /// Revalidates the relay owner at the main-actor target-resolution boundary.
    /// An ingress snapshot cannot grant authority after a surface becomes local.
    func remoteRelayTargetIsCurrent(
        routing: ControlRoutingSelectors,
        workspace: Workspace,
        surfaceID: UUID? = nil
    ) -> Bool {
        guard let owner = routing.remoteRelayOwnerWorkspaceID else { return true }
        guard workspace.id == owner,
              let configuration = workspace.remoteConfiguration,
              configuration.ownerWorkspaceID == owner,
              let connectionID = routing.remoteRelayConnectionID,
              workspace.activeRemoteSessionControllerID == connectionID else { return false }
        guard let surfaceID = surfaceID ?? routing.surfaceID else { return true }
        return workspace.isRemoteTerminalContext(surfaceID)
    }

    /// A destination workspace can retain a moved remote surface for local
    /// lifecycle handling while the relay owner remains the launch workspace.
    /// Read paths must apply that same provenance boundary before returning
    /// surface IDs or summaries.
    func remoteRelaySurfaceIsOwnedByWorkspace(
        _ surfaceID: UUID,
        workspace: Workspace,
        ownerWorkspaceID: UUID
    ) -> Bool {
        guard workspace.id == ownerWorkspaceID,
              workspace.isRemoteTerminalContext(surfaceID) else {
            return false
        }
        if let origin = workspace.surfaceRegistry.remoteTTYReportOriginWorkspaceIDs[surfaceID] {
            return origin == ownerWorkspaceID
        }
        if case .pane = workspace.remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) {
            return true
        }
        return false
    }

    /// Checks an ingress-authorized request again in the same main-actor turn
    /// as its mutation. Controller retirement and live surface changes revoke it.
    func controlRemoteRelayDispatchError(method: String, params: [String: JSONValue]) -> ControlCallResult? {
        guard params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey] != nil else { return nil }
        guard case .string(let ownerRaw)? = params[WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey],
              let owner = UUID(uuidString: ownerRaw) else {
            return .err(code: "remote_relay_authentication_failed", message: remoteRelayAuthenticationFailedMessage, data: nil)
        }
        guard let snapshot = remoteRelayAuthorizationSnapshot(ownerWorkspaceID: owner),
              params[WorkspaceRemoteRelayCommandRewriter.connectionIDKey] == .string(snapshot.connectionID.uuidString) else {
            // `workspace.list` owns its stale-owner response shaping. Let the
            // authoritative app-side read path distinguish a retired/unknown
            // owner from local socket authentication without exposing local
            // TabManager details. Every other method remains fail-closed here.
            if method == "workspace.list" {
                switch remoteRelayAuthorizationPolicy().validate(
                    method: method,
                    parameters: params.mapValues(\.foundationObject),
                    ownerWorkspaceID: owner,
                    surfaceIDs: []
                ) {
                case .allowed:
                    return nil
                case .denied(let code, let message):
                    return .err(code: code, message: message, data: nil)
                }
            }
            return .err(code: "remote_relay_authentication_failed", message: remoteRelayAuthenticationFailedMessage, data: nil)
        }
        switch remoteRelayAuthorizationPolicy().validate(method: method,
            parameters: params.mapValues(\.foundationObject), ownerWorkspaceID: owner, surfaceIDs: snapshot.surfaceIDs) {
        case .allowed: return nil
        case .denied(let code, let message): return .err(code: code, message: message, data: nil)
        }
    }

}
