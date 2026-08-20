import CmuxControlSocket
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

    private nonisolated static let remoteRelayAllowedMethods: Set<String> = [
        "system.ping",
        "system.capabilities",
        "workspace.current",
        "workspace.remote.status",
        "workspace.remote.reconnect",
        "workspace.remote.terminal_session_launching",
        "workspace.remote.terminal_session_connected",
        "workspace.remote.terminal_session_end",
        "surface.list",
        "surface.current",
        "surface.read_text",
        "surface.resume.set",
        "surface.resume.get",
        "surface.resume.clear",
        "surface.report_tty",
        "surface.report_pwd",
        "surface.report_git_branch",
        "surface.clear_git_branch",
        "surface.report_shell_state",
        "surface.ports_kick",
        "agent.resolve_delivery_target",
        "notification.create",
        "notification.create_for_target",
    ]

    private nonisolated static let remoteRelayWorkspaceRequiredMethods: Set<String> = [
        "workspace.current",
        "workspace.remote.status",
        "workspace.remote.reconnect",
        "workspace.remote.terminal_session_launching",
        "workspace.remote.terminal_session_connected",
        "workspace.remote.terminal_session_end",
        "surface.list",
        "surface.current",
        "surface.resume.set",
        "surface.resume.get",
        "surface.resume.clear",
        "surface.report_tty",
        "surface.report_pwd",
        "surface.report_git_branch",
        "surface.clear_git_branch",
        "surface.report_shell_state",
        "surface.ports_kick",
        "notification.create",
        "notification.create_for_target",
    ]

    private nonisolated static let remoteRelaySurfaceRequiredMethods: Set<String> = [
        "workspace.remote.terminal_session_launching",
        "workspace.remote.terminal_session_connected",
        "workspace.remote.terminal_session_end",
        "surface.resume.set",
        "surface.resume.get",
        "surface.resume.clear",
        "surface.read_text",
        "notification.create_for_target",
    ]

    private nonisolated static let remoteRelayWorkspaceSelectorKeys: Set<String> = [
        "workspace_id",
        "preferred_workspace_id",
        "selected_workspace_id",
        "before_workspace_id",
        "after_workspace_id",
        "from_workspace_id",
        "to_workspace_id",
        "tab_id",
        "_cmux_remote_workspace_id",
    ]

    private nonisolated static let remoteRelayWorkspaceArrayKeys: Set<String> = ["workspace_ids"]

    private nonisolated static let remoteRelaySurfaceSelectorKeys: Set<String> = [
        "panel_id",
        "surface_id",
        "preferred_panel_id",
        "preferred_surface_id",
        "target_panel_id",
        "target_surface_id",
        "created_panel_id",
        "created_surface_id",
        "before_panel_id",
        "before_surface_id",
        "after_panel_id",
        "after_surface_id",
    ]

    private nonisolated static let remoteRelaySurfaceArrayKeys: Set<String> = ["panel_ids", "surface_ids"]

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
        guard Self.remoteRelayAllowedMethods.contains(request.method) else {
            return deniedRemoteRelayRequest(
                request,
                code: "remote_relay_method_denied",
                message: "Relay method is not permitted"
            )
        }
        let selectorValidation = Self.validateRemoteRelaySelectors(
            foundationParams,
            ownerWorkspaceID: snapshot.ownerWorkspaceID,
            surfaceIDs: snapshot.surfaceIDs
        )
        if let selectorValidation {
            return deniedRemoteRelayRequest(
                request,
                code: selectorValidation.code,
                message: selectorValidation.message
            )
        }

        let hasWorkspaceSelector = Self.containsTopLevelSelector(
            foundationParams,
            keys: Self.remoteRelayWorkspaceSelectorKeys.subtracting([WorkspaceRemoteRelayCommandRewriter.remoteWorkspaceIDKey])
        )
        let hasSurfaceSelector = Self.containsTopLevelSelector(
            foundationParams,
            keys: Self.remoteRelaySurfaceSelectorKeys
        )
        if Self.remoteRelayWorkspaceRequiredMethods.contains(request.method), !hasWorkspaceSelector {
            return deniedRemoteRelayRequest(
                request,
                code: "remote_relay_workspace_denied",
                message: "Relay method requires an explicit workspace selector"
            )
        }
        if Self.remoteRelaySurfaceRequiredMethods.contains(request.method), !hasSurfaceSelector {
            return deniedRemoteRelayRequest(
                request,
                code: "remote_relay_surface_denied",
                message: "Relay method requires an explicit surface selector"
            )
        }

        if request.method == "agent.resolve_delivery_target" {
            guard foundationParams["pid"] == nil,
                  foundationParams["pid_resolution"] == nil,
                  foundationParams["tty_name"] is String,
                  (foundationParams["tty_resolution"] as? String) == "reported_tty" else {
                return deniedRemoteRelayRequest(
                    request,
                    code: "remote_relay_method_denied",
                    message: "Relay delivery resolution requires the authenticated TTY path"
                )
            }
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

    private struct RemoteRelaySelectorValidation {
        let code: String
        let message: String
    }

    private nonisolated static func containsTopLevelSelector(
        _ params: [String: Any],
        keys: Set<String>
    ) -> Bool {
        keys.contains { key in
            guard let value = params[key] else { return false }
            return !(value is NSNull)
        }
    }

    private nonisolated static func validateRemoteRelaySelectors(
        _ params: [String: Any],
        ownerWorkspaceID: UUID,
        surfaceIDs: Set<UUID>
    ) -> RemoteRelaySelectorValidation? {
        func validate(_ value: Any, key: String?) -> RemoteRelaySelectorValidation? {
            if let dictionary = value as? [String: Any] {
                for (childKey, childValue) in dictionary {
                    if let failure = validate(childValue, key: childKey) { return failure }
                }
                return nil
            }
            if let array = value as? [Any] {
                let childKey: String?
                if let key, remoteRelayWorkspaceArrayKeys.contains(key) {
                    childKey = "workspace_id"
                } else if let key, remoteRelaySurfaceArrayKeys.contains(key) {
                    childKey = "surface_id"
                } else {
                    childKey = key
                }
                for element in array {
                    if let failure = validate(element, key: childKey) { return failure }
                }
                return nil
            }
            guard let key,
                  remoteRelayWorkspaceSelectorKeys.contains(key) || remoteRelaySurfaceSelectorKeys.contains(key) else {
                return nil
            }
            if value is NSNull { return nil }
            guard let raw = value as? String,
                  let id = UUID(uuidString: raw) else {
                return RemoteRelaySelectorValidation(
                    code: key.contains("workspace") || key == "tab_id"
                        ? "remote_relay_workspace_denied"
                        : "remote_relay_surface_denied",
                    message: "Relay selector is invalid"
                )
            }
            if remoteRelayWorkspaceSelectorKeys.contains(key), id != ownerWorkspaceID {
                return RemoteRelaySelectorValidation(
                    code: "remote_relay_workspace_denied",
                    message: "Relay request targets a different workspace"
                )
            }
            if remoteRelaySurfaceSelectorKeys.contains(key), !surfaceIDs.contains(id) {
                return RemoteRelaySelectorValidation(
                    code: "remote_relay_surface_denied",
                    message: "Relay request targets a surface outside its workspace"
                )
            }
            return nil
        }
        return validate(params, key: nil)
    }
}
