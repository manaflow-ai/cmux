public import Foundation

/// Defense-in-depth syntax and method policy for one command arriving through
/// a reverse relay. The app's live workspace gate remains authoritative for
/// ownership; this package gate blocks malformed, future, or command-bearing
/// requests before they reach the local socket.
public struct RemoteRelayCommandPolicy: Sendable {
    /// The result of evaluating one newline-terminated relay request.
    public enum Verdict: Sendable, Equatable {
        /// The request has a known method and safe parameter shape.
        case allow
        /// The request must be rejected before local-socket forwarding.
        case deny(reason: String)
    }

    // These sets are consumed by the app-side alias rewriter as well. Keeping
    // one spelling source prevents selector drift between the two boundaries.
    public static let workspaceIDKeys: Set<String> = [
        "workspace_id", "preferred_workspace_id", "selected_workspace_id",
        "before_workspace_id", "after_workspace_id", "from_workspace_id",
        "to_workspace_id", "sender_workspace_id",
    ]
    public static let surfaceIDKeys: Set<String> = [
        "panel_id", "surface_id", "terminal_id", "preferred_panel_id",
        "preferred_surface_id", "target_panel_id", "target_surface_id",
        "created_panel_id", "created_surface_id", "before_panel_id",
        "before_surface_id", "after_panel_id", "after_surface_id",
        "sender_surface_id",
    ]
    public static let ambiguousIDKeys: Set<String> = ["tab_id", "surface", "target"]
    public static let workspaceIDArrayKeys: Set<String> = ["workspace_ids"]
    public static let surfaceIDArrayKeys: Set<String> = ["panel_ids", "surface_ids"]
    public static let ambiguousIDArrayKeys: Set<String> = ["tab_ids", "tab_id_groups"]

    private static let commandKeys: Set<String> = [
        "command", "initial_command", "initial_input", "tmux_start_command",
        "pane_start_command", "working_directory", "startup_environment",
        "remote_pty_session_id", "remote_context", "shell", "profile", "cwd",
        "environment",
    ]

    private static let selectorKeys: Set<String> = workspaceIDKeys
        .union(surfaceIDKeys)
        .union(ambiguousIDKeys)
        .union(workspaceIDArrayKeys)
        .union(surfaceIDArrayKeys)
        .union(ambiguousIDArrayKeys)

    /// Creates the stateless relay command policy.
    public init() {}

    /// Filters discovery to reviewed relay methods without granting access.
    /// Each call still requires the method's parameter contract and live owner checks.
    /// - Parameter methods: Method names advertised by the local server.
    /// - Returns: Only exact methods with an explicit relay parameter contract.
    public func permittedMethods(from methods: [String]) -> [String] {
        let schema = RemoteRelayRoutingSchema()
        return methods.filter { schema.parameters(for: $0) != nil }
    }

    /// Evaluates one complete command line before rewriting or forwarding.
    /// Alias dictionaries identify the remote session's owned object IDs. The
    /// app-side authorization gate repeats the same checks after rewriting.
    public func evaluate(
        commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Verdict {
        guard let line = String(data: commandLine, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            line.hasPrefix("{"),
            let data = line.data(using: .utf8),
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawMethod = request["method"] as? String,
            request["params"] == nil || request["params"] is [String: Any] else {
            return .deny(reason: "remote relay commands must be v2 JSON-RPC requests")
        }
        let method = rawMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !method.isEmpty, RemoteRelayRoutingSchema().parameters(for: method) != nil else {
            return .deny(reason: "method '\(rawMethod)' is not permitted through a remote relay")
        }

        let params = request["params"] as? [String: Any] ?? [:]
        if let key = firstKey(in: params, matching: Self.commandKeys) {
            return .deny(reason: "parameter '\(key)' is not permitted through a remote relay")
        }
        if method == "surface.split" {
            if let rawType = params["type"] as? String,
               rawType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "terminal" {
                return .deny(reason: "relay splits are limited to terminal surfaces")
            }
            if params["url"] != nil, !(params["url"] is NSNull) {
                return .deny(reason: "relay browser URLs are not permitted")
            }
        }
        if method == "agent.resolve_delivery_target" {
            if firstKey(in: params, matching: ["pid", "pid_resolution"]) != nil {
                return .deny(reason: "agent PID resolution is not permitted through a remote relay")
            }
            guard params["tty_name"] is String,
                  params["tty_resolution"] as? String == "reported_tty" else {
                return .deny(reason: "agent delivery resolution requires the authenticated TTY path")
            }
        }
        if method == "surface.send_key" {
            guard let key = params["key"] as? String,
                  ["return", "enter", "tab", "ctrl+enter"].contains(key.lowercased()) else {
                return .deny(reason: "relay submit keys are limited to return, enter, tab, and ctrl+enter")
            }
        }
        if method == "terminal.paste" {
            guard params["text"] is String,
                  let submitKey = params["submit_key"] as? String,
                  submitKey == "none" else {
                return .deny(reason: "terminal.paste requires text and submit_key none")
            }
        }

        if let denial = agentMessageDenial(
            method: method,
            params: params,
            workspaceAliases: workspaceAliases,
            surfaceAliases: surfaceAliases
        ) {
            return denial
        }

        if let malformedSelector = malformedSelector(in: params, key: nil) {
            return .deny(reason: "selector '\(malformedSelector)' is invalid")
        }
        if let key = RemoteRelayRoutingSchema().unsupportedKey(in: params, method: method) {
            return .deny(reason: "parameter '\(key)' is not permitted through a remote relay")
        }
        return .allow
    }

    private func agentMessageDenial(
        method: String,
        params: [String: Any],
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Verdict? {
        switch method {
        case "agent.message.poll", "agent.message.claim", "agent.message.mark_read":
            guard ownedID(params["surface_id"], aliases: surfaceAliases) != nil else {
                return .deny(reason: "agent message method requires an owned surface_id")
            }
            if method == "agent.message.mark_read",
               params["id"] != nil || params["ids"] != nil {
                return .deny(reason: "agent.message.mark_read cannot use unscoped message ids")
            }
        case "agent.message.list":
            guard ownedID(
                params["surface"],
                workspaceAliases: workspaceAliases,
                surfaceAliases: surfaceAliases
            ) != nil else {
                return .deny(reason: "agent.message.list requires an owned surface target")
            }
        case "agent.message.send":
            if params["reply_to"] != nil {
                return .deny(reason: "agent.message.send cannot use reply_to through a remote relay")
            }
            guard ownedID(
                params["target"],
                workspaceAliases: workspaceAliases,
                surfaceAliases: surfaceAliases
            ) != nil else {
                return .deny(reason: "agent.message.send requires an owned target")
            }
            if let senderSurface = params["sender_surface_id"],
               ownedID(senderSurface, aliases: surfaceAliases) == nil {
                return .deny(reason: "agent.message.send sender_surface_id is not owned")
            }
            if let senderWorkspace = params["sender_workspace_id"],
               ownedID(senderWorkspace, aliases: workspaceAliases) == nil {
                return .deny(reason: "agent.message.send sender_workspace_id is not owned")
            }
        default:
            return nil
        }
        return nil
    }

    private func ownedID(_ value: Any?, aliases: [UUID: UUID]) -> UUID? {
        guard let raw = value as? String,
              let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return aliases[id] == nil ? nil : id
    }

    private func ownedID(
        _ value: Any?,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> UUID? {
        ownedID(value, aliases: workspaceAliases) ?? ownedID(value, aliases: surfaceAliases)
    }

    private func firstKey(in value: Any, matching keys: Set<String>) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() where keys.contains(key) {
                if !(dictionary[key] is NSNull) { return key }
            }
            for child in dictionary.values {
                if let found = firstKey(in: child, matching: keys) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstKey(in: child, matching: keys) { return found }
            }
        }
        return nil
    }

    private func malformedSelector(in value: Any, key: String?) -> String? {
        if let key, Self.workspaceIDKeys.union(Self.surfaceIDKeys).union(Self.ambiguousIDKeys).contains(key),
           !(value is String) { return key }
        if let dictionary = value as? [String: Any] {
            for (childKey, childValue) in dictionary {
                if let failure = malformedSelector(in: childValue, key: childKey) {
                    return failure
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            let elementKey: String?
            if let key, Self.workspaceIDArrayKeys.contains(key) { elementKey = "workspace_id" }
            else if let key, Self.surfaceIDArrayKeys.contains(key) { elementKey = "surface_id" }
            else if let key, Self.ambiguousIDArrayKeys.contains(key) { elementKey = "tab_id" }
            else { elementKey = key }
            for child in array {
                if let failure = malformedSelector(in: child, key: elementKey) { return failure }
            }
            return nil
        }
        guard let key, Self.selectorKeys.contains(key) else { return nil }
        guard let raw = value as? String,
              UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            return key
        }
        return nil
    }
}
