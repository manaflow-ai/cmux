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
        case "agent.resolve_delivery_target": return workspace.union(["tty_name", "tty_resolution"])
        case "agent.hook.enqueue":
            return surface.union([
                "agent", "subcommand", "payload", "relay_backed", "caller_tty",
                "remote_cwd", "ancestor_executables",
            ])
        case "notification.create_for_target":
            return surface.union(["title", "subtitle", "body", "reply_shape"])
        default: return nil
        }
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
        // The resume binding fields ride only on SessionStart, where the Mac
        // publishes the binding. They name data, never a command: the Mac
        // builds the resume argv itself.
        for key in ["remote_cwd", "ancestor_executables"] where parameters[key] != nil {
            guard subcommand == "session-start" else { return key }
        }
        if let rawCwd = parameters["remote_cwd"] {
            guard let cwd = rawCwd as? String,
                  Self.isAdmissibleRelayRemoteWorkingDirectory(cwd) else { return "remote_cwd" }
        }
        if let rawAncestors = parameters["ancestor_executables"] {
            guard Self.admissibleRelayAncestorExecutables(rawAncestors) != nil else {
                return "ancestor_executables"
            }
        }
        return nil
    }

    // Mirrors `RelayAgentResumeContext` in CMUXAgentLaunch, which the CLI
    // re-checks after admission; this package does not depend on it.
    static let maximumRelayRemoteWorkingDirectoryBytes = 1_024
    static let maximumRelayAncestors = 8
    static let maximumRelayAncestorWords = 6
    static let maximumRelayAncestorWordBytes = 128
    static let maximumRelayAncestorBytes = 2_048

    /// Punctuation a relayed remote directory may use besides letters, digits, and marks. The
    /// Mac types the path into a remote shell whose dialect it cannot see, so quotes,
    /// backslashes, and shell metacharacters are refused rather than escaped.
    static let relayRemoteWorkingDirectoryPunctuation = " /._-+,@:=~%"

    /// An absolute remote path within bounds that uses only letters, digits, marks, and
    /// ``relayRemoteWorkingDirectoryPunctuation``.
    static func isAdmissibleRelayRemoteWorkingDirectory(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= maximumRelayRemoteWorkingDirectoryBytes
            && value.unicodeScalars.allSatisfy { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || relayRemoteWorkingDirectoryPunctuation.unicodeScalars.contains(scalar)
            }
    }

    /// Ancestor argv words within the relay bounds: at most 8 ancestors of 1 to 6
    /// words, 128 bytes per word, 2 KiB in total, no control characters.
    static func admissibleRelayAncestorExecutables(_ value: Any) -> [[String]]? {
        guard let ancestors = value as? [Any], ancestors.count <= maximumRelayAncestors else { return nil }
        var total = 0
        var result: [[String]] = []
        for ancestor in ancestors {
            guard let words = ancestor as? [Any], !words.isEmpty,
                  words.count <= maximumRelayAncestorWords else { return nil }
            var admitted: [String] = []
            for word in words {
                guard let text = word as? String,
                      text.utf8.count <= maximumRelayAncestorWordBytes,
                      !containsControlCharacter(text) else { return nil }
                total += text.utf8.count
                admitted.append(text)
            }
            result.append(admitted)
        }
        return total <= maximumRelayAncestorBytes ? result : nil
    }

    /// Whether `value` holds a C0 or C1 control character, DEL, a line or paragraph separator, or
    /// a bidirectional formatting character.
    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0..<0x20, 0x7F...0x9F, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069:
                return true
            default:
                return false
            }
        }
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
