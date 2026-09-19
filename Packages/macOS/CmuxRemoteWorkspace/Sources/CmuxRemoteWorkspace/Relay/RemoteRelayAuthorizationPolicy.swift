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
        "surface.close",
        "surface.send_text",
        "surface.report_tty",
        "surface.report_pwd",
        "surface.report_git_branch",
        "surface.clear_git_branch",
        "surface.report_shell_state",
        "surface.ports_kick",
        "workspace.equalize_splits",
    ]

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
        "agent.restore.admit",
        "agent.restore.release",
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
        "agent.restore.admit",
        "agent.restore.release",
        "surface.read_text",
        "surface.read_selection",
        "notification.create_for_target",
        "surface.report_tty",
        "surface.report_pwd",
        "surface.report_git_branch",
        "surface.clear_git_branch",
        "surface.report_shell_state",
        "surface.ports_kick",
        "surface.split",
        "surface.close",
        "surface.send_text",
    ]

    private static let exactSurfaceSelectorMethods: Set<String> = [
        "surface.split",
        "surface.close",
        "surface.send_text",
        "surface.report_tty",
        "surface.report_pwd",
        "surface.report_git_branch",
        "surface.clear_git_branch",
        "surface.report_shell_state",
        "surface.ports_kick",
    ]

    private static let workspaceSelectorKeys: Set<String> = [
        "workspace_id",
        remoteWorkspaceIDKey,
    ]

    private static let workspaceArrayKeys: Set<String> = ["workspace_ids"]

    private static let surfaceSelectorKeys: Set<String> = [
        "surface_id",
        "terminal_id",
    ]

    private static let surfaceArrayKeys: Set<String> = ["panel_ids", "surface_ids"]

    /// Parameters that can select a container outside the authenticated
    /// workspace.  The relay protocol intentionally requires workspace/surface
    /// UUIDs and does not accept focus/window/pane fallback selectors.
    private static let unsupportedContainerSelectorKeys: Set<String> = [
        "window_id", "group_id", "pane_id",
    ]

    /// Creation and shell parameters are rejected for relay requests.  A
    /// remote split is only safe when it is routed by the existing remote
    /// transport; caller supplied startup options can force a local shell.
    private static let localExecutionKeys: Set<String> = [
        "initial_command", "initial_input", "tmux_start_command",
        "pane_start_command", "working_directory", "startup_environment",
        "remote_pty_session_id", "remote_context", "shell", "profile",
        "cwd", "environment",
    ]

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
        guard RemoteRelayRoutingSchema().parameters(for: method) != nil else {
            return .denied(
                code: "remote_relay_method_denied",
                message: "Relay method is not permitted"
            )
        }

        if method != "surface.resume.set",
           let key = firstParameterKey(
               in: parameters,
               keys: Self.localExecutionKeys.union(["command"])
           ) {
            return .denied(
                code: "remote_relay_method_denied",
                message: "Relay parameter '\(key)' is not permitted"
            )
        }

        if let key = firstParameterKey(in: parameters, keys: Self.unsupportedContainerSelectorKeys) {
            return .denied(
                code: "remote_relay_workspace_denied",
                message: "Relay selector '\(key)' is not permitted"
            )
        }

        if method == "surface.split" {
            if let rawType = parameters["type"] as? String,
               rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "terminal" {
                return .denied(
                    code: "remote_relay_method_denied",
                    message: "Relay splits are limited to terminal surfaces"
                )
            }
            if parameters["url"] != nil, !(parameters["url"] is NSNull) {
                return .denied(
                    code: "remote_relay_method_denied",
                    message: "Relay browser URLs are not permitted"
                )
            }
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
        if Self.workspaceRequiredMethods.contains(method),
           !(parameters["workspace_id"] is String) {
            return .denied(
                code: "remote_relay_workspace_denied",
                message: "Relay method requires an explicit workspace_id selector"
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

        if method == "notification.create_for_target",
           !(parameters["surface_id"] is String) {
            return .denied(
                code: "remote_relay_surface_denied",
                message: "Relay notification delivery requires an explicit surface_id selector"
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
        if let key = RemoteRelayRoutingSchema().unsupportedKey(in: parameters, method: method) {
            return .denied(
                code: "remote_relay_method_denied",
                message: "Relay parameter '\(key)' is not permitted"
            )
        }
        return .allowed
    }

    private func firstParameterKey(in value: Any, keys: Set<String>) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() where keys.contains(key) {
                if !(dictionary[key] is NSNull) { return key }
            }
            for child in dictionary.values {
                if let found = firstParameterKey(in: child, keys: keys) { return found }
            }
            return nil
        }
        if let array = value as? [Any] {
            for child in array {
                if let found = firstParameterKey(in: child, keys: keys) { return found }
            }
        }
        return nil
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
        if let key, Self.workspaceSelectorKeys.contains(key) || Self.surfaceSelectorKeys.contains(key),
           !(value is String) {
            return SelectorFailure(code: "remote_relay_surface_denied", message: "Relay selector is invalid")
        }
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
