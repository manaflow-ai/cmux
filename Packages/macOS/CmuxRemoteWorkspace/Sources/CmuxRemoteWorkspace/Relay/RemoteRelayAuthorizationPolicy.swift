public import Foundation

/// Pure, workspace-scoped authorization for requests arriving through the
/// remote CLI relay.
///
/// The policy deliberately receives only decoded values and an authoritative
/// workspace/surface snapshot. Authentication, snapshot acquisition, response
/// encoding, and command dispatch remain in the app composition layer.
public struct RemoteRelayAuthorizationPolicy: Sendable {
    /// The outcome of validating one relay method and its selectors.
    public enum Decision: Equatable, Sendable {
        /// The request satisfies the method and selector policy.
        case allowed
        /// The request must be rejected with the supplied stable code/message.
        case denied(code: String, message: String)
    }

    /// The relay provenance key used when excluding the authenticated owner
    /// marker from the explicit workspace-selector requirement.
    public static let remoteWorkspaceIDKey = "_cmux_remote_workspace_id"

    private static let tmuxCompatibleMethods: Set<String> = [
        "surface.split",
        "surface.respawn",
        "surface.close",
        "surface.send_text",
        "workspace.equalize_splits",
        "pane.list",
        "pane.surfaces",
        "pane.focus",
        "pane.last",
        "pane.resize",
    ]

    private static let allowedMethods: Set<String> = Set([
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
        "surface.read_selection",
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
    ]).union(tmuxCompatibleMethods)

    private static let workspaceRequiredMethods: Set<String> = Set([
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
    ]).union(tmuxCompatibleMethods)

    private static let surfaceRequiredMethods: Set<String> = [
        "workspace.remote.terminal_session_launching",
        "workspace.remote.terminal_session_connected",
        "workspace.remote.terminal_session_end",
        "surface.resume.set",
        "surface.resume.get",
        "surface.resume.clear",
        "surface.read_text",
        "surface.read_selection",
        "notification.create_for_target",
        "surface.split",
        "surface.respawn",
        "surface.close",
        "surface.send_text",
    ]

    private static let exactSurfaceSelectorMethods: Set<String> = [
        "surface.split",
        "surface.respawn",
        "surface.close",
        "surface.send_text",
    ]

    private static let workspaceSelectorKeys: Set<String> = [
        "workspace_id",
        "preferred_workspace_id",
        "selected_workspace_id",
        "before_workspace_id",
        "after_workspace_id",
        "from_workspace_id",
        "to_workspace_id",
        "tab_id",
        remoteWorkspaceIDKey,
    ]

    private static let workspaceArrayKeys: Set<String> = ["workspace_ids"]

    private static let surfaceSelectorKeys: Set<String> = [
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

    private static let surfaceArrayKeys: Set<String> = ["panel_ids", "surface_ids"]

    /// Creates the default relay authorization policy.
    public init() {}

    /// Validates a decoded relay request against one owner's live snapshot.
    ///
    /// - Parameters:
    ///   - method: Decoded control-socket method name.
    ///   - parameters: Decoded Foundation parameter object.
    ///   - ownerWorkspaceID: Workspace authenticated by the relay metadata.
    ///   - surfaceIDs: Surface IDs currently owned by that workspace.
    /// - Returns: `.allowed`, or a stable denial code and message.
    public func validate(
        method: String,
        parameters: [String: Any],
        ownerWorkspaceID: UUID,
        surfaceIDs: Set<UUID>
    ) -> Decision {
        guard Self.allowedMethods.contains(method) else {
            return .denied(
                code: "remote_relay_method_denied",
                message: "Relay method is not permitted"
            )
        }

        if let selectorFailure = validateSelectors(
            parameters,
            ownerWorkspaceID: ownerWorkspaceID,
            surfaceIDs: surfaceIDs
        ) {
            return .denied(code: selectorFailure.code, message: selectorFailure.message)
        }

        let hasWorkspaceSelector = containsTopLevelSelector(
            parameters,
            keys: Self.workspaceSelectorKeys.subtracting([Self.remoteWorkspaceIDKey])
        )
        let hasSurfaceSelector = containsTopLevelSelector(
            parameters,
            keys: Self.surfaceSelectorKeys
        )
        if Self.workspaceRequiredMethods.contains(method), !hasWorkspaceSelector {
            return .denied(
                code: "remote_relay_workspace_denied",
                message: "Relay method requires an explicit workspace selector"
            )
        }
        if Self.surfaceRequiredMethods.contains(method), !hasSurfaceSelector {
            return .denied(
                code: "remote_relay_surface_denied",
                message: "Relay method requires an explicit surface selector"
            )
        }

        // Aliases are validated above, but handlers for these tmux-compatible
        // methods consume only the exact keys below; requiring them prevents a
        // missing handler argument from falling back to focused routing.
        if Self.tmuxCompatibleMethods.contains(method),
           !(parameters["workspace_id"] is String) {
            return .denied(
                code: "remote_relay_workspace_denied",
                message: "Relay tmux-compat methods require an explicit workspace_id selector"
            )
        }
        if Self.exactSurfaceSelectorMethods.contains(method),
           !(parameters["surface_id"] is String) {
            return .denied(
                code: "remote_relay_surface_denied",
                message: "Relay tmux-compat surface methods require an explicit surface_id selector"
            )
        }

        if method == "agent.resolve_delivery_target" {
            guard parameters["pid"] == nil,
                  parameters["pid_resolution"] == nil,
                  parameters["tty_name"] is String,
                  (parameters["tty_resolution"] as? String) == "reported_tty" else {
                return .denied(
                    code: "remote_relay_method_denied",
                    message: "Relay delivery resolution requires the authenticated TTY path"
                )
            }
        }
        return .allowed
    }

    private struct SelectorFailure {
        let code: String
        let message: String
    }

    private func containsTopLevelSelector(
        _ parameters: [String: Any],
        keys: Set<String>
    ) -> Bool {
        keys.contains { key in
            guard let value = parameters[key] else { return false }
            return !(value is NSNull)
        }
    }

    private func validateSelectors(
        _ parameters: [String: Any],
        ownerWorkspaceID: UUID,
        surfaceIDs: Set<UUID>
    ) -> SelectorFailure? {
        validateSelectorValue(
            parameters,
            key: nil,
            ownerWorkspaceID: ownerWorkspaceID,
            surfaceIDs: surfaceIDs
        )
    }

    private func validateSelectorValue(
        _ value: Any,
        key: String?,
        ownerWorkspaceID: UUID,
        surfaceIDs: Set<UUID>
    ) -> SelectorFailure? {
        if let dictionary = value as? [String: Any] {
            for (childKey, childValue) in dictionary {
                if let failure = validateSelectorValue(
                    childValue,
                    key: childKey,
                    ownerWorkspaceID: ownerWorkspaceID,
                    surfaceIDs: surfaceIDs
                ) {
                    return failure
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            let childKey: String?
            if let key, Self.workspaceArrayKeys.contains(key) {
                childKey = "workspace_id"
            } else if let key, Self.surfaceArrayKeys.contains(key) {
                childKey = "surface_id"
            } else {
                childKey = key
            }
            for element in array {
                if let failure = validateSelectorValue(
                    element,
                    key: childKey,
                    ownerWorkspaceID: ownerWorkspaceID,
                    surfaceIDs: surfaceIDs
                ) {
                    return failure
                }
            }
            return nil
        }

        guard let key,
              Self.workspaceSelectorKeys.contains(key) || Self.surfaceSelectorKeys.contains(key) else {
            return nil
        }
        if value is NSNull { return nil }
        guard let raw = value as? String,
              let id = UUID(uuidString: raw) else {
            return SelectorFailure(
                code: key.contains("workspace") || key == "tab_id"
                    ? "remote_relay_workspace_denied"
                    : "remote_relay_surface_denied",
                message: "Relay selector is invalid"
            )
        }
        if Self.workspaceSelectorKeys.contains(key), id != ownerWorkspaceID {
            return SelectorFailure(
                code: "remote_relay_workspace_denied",
                message: "Relay request targets a different workspace"
            )
        }
        if Self.surfaceSelectorKeys.contains(key), !surfaceIDs.contains(id) {
            return SelectorFailure(
                code: "remote_relay_surface_denied",
                message: "Relay request targets a surface outside its workspace"
            )
        }
        return nil
    }
}
