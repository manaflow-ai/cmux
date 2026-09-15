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
        "to_workspace_id",
    ]
    public static let surfaceIDKeys: Set<String> = [
        "panel_id", "surface_id", "terminal_id", "preferred_panel_id",
        "preferred_surface_id", "target_panel_id", "target_surface_id",
        "created_panel_id", "created_surface_id", "before_panel_id",
        "before_surface_id", "after_panel_id", "after_surface_id",
    ]
    public static let ambiguousIDKeys: Set<String> = ["tab_id"]
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

    /// Evaluates one complete command line before rewriting or forwarding.
    /// Alias dictionaries are accepted for API compatibility; live ownership
    /// is checked later by the app-side authorization gate.
    public func evaluate(
        commandLine: Data,
        workspaceAliases _: [UUID: UUID],
        surfaceAliases _: [UUID: UUID]
    ) -> Verdict {
        guard let line = String(data: commandLine, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            line.hasPrefix("{"),
            let data = line.data(using: .utf8),
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawMethod = request["method"] as? String else {
            return .deny(reason: "remote relay commands must be v2 JSON-RPC requests")
        }
        let method = rawMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !method.isEmpty, RemoteRelayRoutingSchema().parameters(for: method) != nil else {
            return .deny(reason: "method '\(rawMethod)' is not permitted through a remote relay")
        }

        let params = request["params"] as? [String: Any] ?? [:]
        if method != "surface.resume.set",
           let key = firstKey(in: params, matching: Self.commandKeys) {
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

        if let malformedSelector = malformedSelector(in: params, key: nil) {
            return .deny(reason: "selector '\(malformedSelector)' is invalid")
        }
        if let key = RemoteRelayRoutingSchema().unsupportedKey(in: params, method: method) {
            return .deny(reason: "parameter '\(key)' is not permitted through a remote relay")
        }
        return .allow
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
