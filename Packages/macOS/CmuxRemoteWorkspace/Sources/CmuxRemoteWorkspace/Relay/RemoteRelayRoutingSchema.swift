import Foundation

/// Restricts routing to the selectors consumed by each allowed relay handler.
struct RemoteRelayRoutingSchema {
    func unsupportedKey(in parameters: [String: Any], method: String) -> String? {
        let keys: Set<String>
        switch method {
        case "surface.read_text", "surface.read_selection",
             "surface.resume.set", "surface.resume.get", "surface.resume.clear":
            keys = ["workspace_id", "surface_id", "terminal_id"]
        case "surface.split", "surface.close", "surface.send_text",
             "surface.report_tty", "surface.report_pwd", "surface.report_git_branch",
             "surface.clear_git_branch", "surface.report_shell_state", "surface.ports_kick",
             "workspace.remote.terminal_session_launching", "workspace.remote.terminal_session_connected",
             "workspace.remote.terminal_session_end", "agent.restore.admit", "agent.restore.release",
             "notification.create", "notification.create_for_target":
            keys = ["workspace_id", "surface_id"]
        default:
            keys = ["workspace_id"]
        }
        return unsupportedKey(in: parameters, allowed: keys.union([
            RemoteRelayAuthorizationPolicy.remoteWorkspaceIDKey
        ]))
    }

    private func unsupportedKey(in value: Any, allowed: Set<String>) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                guard let child = dictionary[key] else { continue }
                if isRoutingKey(key), !allowed.contains(key) { return key }
                if let invalid = unsupportedKey(in: child, allowed: allowed) { return invalid }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let invalid = unsupportedKey(in: child, allowed: allowed) { return invalid }
            }
        }
        return nil
    }

    private func isRoutingKey(_ key: String) -> Bool {
        // Reject future selector spellings too: an owned decoy must never
        // authorize a newly introduced target_* selector by accident.
        if RemoteRelayCommandPolicy.workspaceIDKeys.contains(key)
            || RemoteRelayCommandPolicy.surfaceIDKeys.contains(key)
            || RemoteRelayCommandPolicy.ambiguousIDKeys.contains(key)
            || RemoteRelayCommandPolicy.workspaceIDArrayKeys.contains(key)
            || RemoteRelayCommandPolicy.surfaceIDArrayKeys.contains(key)
            || RemoteRelayCommandPolicy.ambiguousIDArrayKeys.contains(key) { return true }
        return ["workspace", "surface", "terminal", "panel", "pane", "window", "group", "tab"].contains { kind in
            key == "\(kind)_id" || key == "\(kind)_ids"
                || key.hasSuffix("_\(kind)_id") || key.hasSuffix("_\(kind)_ids")
        }
    }
}
