import Foundation

/// Closed parameter contracts for the methods intentionally exposed to a relay.
/// Adding a handler parameter does not expose it remotely until it is reviewed here.
struct RemoteRelayRoutingSchema {
    /// Returns the reviewed parameter names for a relay method, or `nil` when
    /// the method is not exposed through the relay.
    func parameters(for method: String) -> Set<String>? {
        let workspace: Set<String> = ["workspace_id"]
        let surface = workspace.union(["surface_id"])
        let terminal = surface.union(["terminal_id"])
        switch method {
        case "system.ping", "system.capabilities": return []
        case "workspace.list", "workspace.current", "workspace.remote.status", "surface.list", "surface.current":
            return workspace
        case "workspace.equalize_splits": return workspace.union(["orientation"])
        case "surface.read_text": return terminal.union(["scrollback", "lines"])
        case "surface.read_selection": return terminal
        case "surface.close", "surface.clear_git_branch": return surface
        case "surface.send_text": return surface.union(["text"])
        // Relay splits are limited to terminal surfaces in the current
        // workspace/surface and never carry a command, a working directory, or
        // a startup environment: RemoteRelayCommandPolicy denies every
        // command-bearing key on every method, so the pane's command must
        // arrive separately through surface.send_text (GHSA-9vmv-3hjw-j28c).
        case "surface.split":
            return surface.union(["direction", "type", "focus", "initial_divider_position", "remote_tmux_unsupported_options"])
        case "terminal.paste": return surface.union(["text", "submit_key"])
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
        case "agent.resolve_delivery_target": return workspace.union(["tty_name", "tty_resolution"])
        case "agent.hook.enqueue":
            return surface.union(["agent", "subcommand", "payload", "relay_backed", "caller_tty"])
        case "agent.message.poll":
            return ["surface_id", "poller_key", "register", "mark_delivered_read"]
        case "agent.message.claim":
            return ["surface_id", "via", "mark_delivered_read"]
        case "agent.message.mark_read":
            return ["surface_id", "id", "ids"]
        case "agent.message.list":
            return ["surface", "state", "limit"]
        case "agent.message.send":
            return [
                "target", "reply_to", "body", "from", "thread_id",
                "sender_surface_id", "sender_workspace_id",
            ]
        case "notification.create_for_target":
            return surface.union(["title", "subtitle", "body", "effects"])
        default: return nil
        }
    }

    /// Effect names a relayed notification's `effects` patch may carry.
    static let relayNotificationEffectKeys: Set<String> = [
        "record", "markUnread", "reorderWorkspace", "desktop", "sound", "command", "paneFlash",
    ]

    /// The parameters a relay gate scans for command-bearing keys. A
    /// notification's `effects` patch is left out only when it is a flat
    /// object of known effect names with JSON boolean values: its `command`
    /// entry toggles the user's own `notifications.command` and carries no
    /// command text. Any other shape stays in the scan and is denied.
    func commandKeyScanScope(of parameters: [String: Any], method: String) -> [String: Any] {
        guard method == "notification.create_for_target",
              let effects = parameters["effects"] as? [String: Any],
              effects.allSatisfy({ Self.relayNotificationEffectKeys.contains($0.key) && Self.isJSONBoolean($0.value) })
        else { return parameters }
        var scope = parameters
        scope.removeValue(forKey: "effects")
        return scope
    }

    private static func isJSONBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// Claude lifecycle events a relay host may admit. Decision hooks
    /// (permission feed, CronCreate guard) and auxiliary workers stay local-only,
    /// so a remote host can report state but never answer for the agent.
    static let relayAgentHookSubcommands: Set<String> = [
        "session-start", "prompt-submit", "stop", "notification", "session-end", "pre-tool-use",
    ]
    static let maximumRelayAgentHookPayloadBytes = 8 * 1_024
    static let maximumRelayAgentHookCallerTTYBytes = 256

    /// Returns the first `agent.hook.enqueue` parameter outside the relay
    /// contract. Routing is carried only by the scoped `workspace_id` and
    /// `surface_id` selectors; the app rebuilds the hook environment from them.
    func agentHookContractViolation(in parameters: [String: Any]) -> String? {
        guard parameters["agent"] as? String == "claude" else { return "agent" }
        guard let subcommand = parameters["subcommand"] as? String,
              Self.relayAgentHookSubcommands.contains(subcommand) else { return "subcommand" }
        guard let payload = parameters["payload"] as? String,
              payload.utf8.count <= Self.maximumRelayAgentHookPayloadBytes,
              !payload.contains("\0") else { return "payload" }
        guard parameters["relay_backed"] as? Bool == true else { return "relay_backed" }
        if let rawTTY = parameters["caller_tty"], !(rawTTY is NSNull) {
            guard let callerTTY = rawTTY as? String,
                  callerTTY.utf8.count <= Self.maximumRelayAgentHookCallerTTYBytes,
                  !callerTTY.contains("\0") else { return "caller_tty" }
        }
        return nil
    }

    /// Returns the first parameter outside the method's reviewed contract, or
    /// `nil` when every key and value shape is allowed. Both relay gates report
    /// it with their existing "parameter not permitted" denial.
    func unsupportedKey(in parameters: [String: Any], method: String) -> String? {
        // Hook routing comes only from the owner-checked selectors, so a remote
        // host can report lifecycle state for its own surfaces and cannot pick
        // a decision hook or carry local replay environment.
        if method == "agent.hook.enqueue", let key = agentHookContractViolation(in: parameters) {
            return key
        }
        // `_cmux_remote_relay_authentication_code` is a retired resume MAC that
        // old remote clients may still send; ingress strips it, so allow it here.
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
