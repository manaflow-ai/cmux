import Foundation

/// Closed parameter contracts for the methods intentionally exposed to a relay.
/// Adding a handler parameter does not expose it remotely until it is reviewed here.
struct RemoteRelayRoutingSchema {
    func parameters(for method: String) -> Set<String>? {
        let workspace: Set<String> = ["workspace_id"]
        let surface = workspace.union(["surface_id"])
        let terminal = surface.union(["terminal_id"])
        switch method {
        case "system.ping", "system.capabilities": return []
        case "workspace.list", "workspace.current", "workspace.remote.status", "surface.list", "surface.current":
            return workspace
        case "workspace.remote.reconnect": return surface
        case "workspace.equalize_splits": return workspace.union(["orientation"])
        case "surface.read_text": return terminal.union(["scrollback", "lines"])
        case "surface.read_selection": return terminal
        case "surface.close", "surface.clear_git_branch": return surface
        case "surface.send_text": return surface.union(["text"])
        case "surface.split":
            return surface.union(["direction", "type", "focus", "initial_divider_position", "remote_tmux_unsupported_options"])
        case "surface.report_tty":
            return surface.union(["tty_name", "terminal_lifecycle_id", "attempt_id"])
        case "surface.report_pwd": return surface.union(["path", "directory"])
        case "surface.report_git_branch": return surface.union(["branch", "is_dirty", "status"])
        case "surface.report_shell_state":
            return surface.union(["terminal_lifecycle_id", "state", "shell_state", "activity"])
        case "surface.ports_kick": return surface.union(["reason"])
        case "workspace.remote.terminal_session_launching":
            return surface.union(["terminal_lifecycle_id", "attempt_id"])
        case "workspace.remote.terminal_session_connected":
            return surface.union(["terminal_lifecycle_id", "attempt_id", "relay_port", "session_id", "lifecycle_id"])
        case "workspace.remote.terminal_session_end":
            return surface.union(["terminal_lifecycle_id", "relay_port", "session_id", "lifecycle_id", "lifecycle_only"])
        case "surface.resume.set":
            return terminal.union(["command", "name", "kind", "cwd", "checkpoint_id", "checkpointId",
                "source", "environment", "launch_command", "permission_mode", "auto_resume", "resume_evidence_provenance"])
        case "surface.resume.get":
            return terminal.union(["claim_checkpoint_id", "claim_source", "claim_updated_at"])
        case "surface.resume.clear":
            return terminal.union(["checkpoint_id", "checkpointId", "source", "expected_updated_at", "agent_session_ended"])
        case "agent.restore.admit": return surface.union(["kind", "session_id", "record_session_id"])
        case "agent.restore.release": return surface.union(["kind", "session_id", "claim_id"])
        case "agent.resolve_delivery_target": return workspace.union(["tty_name", "tty_resolution"])
        case "notification.create_for_target":
            return surface.union(["title", "subtitle", "body", "reply_shape"])
        default: return nil
        }
    }

    func unsupportedKey(in parameters: [String: Any], method: String) -> String? {
        let provenance: Set<String> = [
            RemoteRelayAuthorizationPolicy.remoteWorkspaceIDKey,
            "_cmux_remote_connection_id", "_cmux_remote_relay_authentication_code",
            "_cmux_remote_relay_request_authentication_code"
        ]
        guard let contract = self.parameters(for: method) else { return "method" }
        let allowed = contract.union(provenance)
        if let unknown = parameters.keys.sorted().first(where: { !allowed.contains($0) }) {
            return unknown
        }
        return unsupportedKey(in: parameters, allowed: allowed)
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
