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

    private static let remoteHookMethods: Set<String> = [
        "hooks.invoke",
        "hooks.invoke.begin",
        "hooks.invoke.append",
        "hooks.invoke.cancel",
        "hooks.invoke.execute",
    ]

    private static let remoteHookRoutingEnvironmentKeys: Set<String> = [
        "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID",
        "CMUX_AGENT_LAUNCH_KIND", "CMUX_AGENT_LAUNCH_EXECUTABLE",
        "CMUX_AGENT_LAUNCH_ARGV_B64", "CMUX_AGENT_LAUNCH_CWD",
        "CMUX_REMOTE_PTY_SESSION_ID", "CMUX_SSH_PTY_SESSION_ID", "PWD",
        "CMUX_CLI_TTY_NAME", "CMUX_TTY_NAME", "TTY", "SSH_TTY",
    ]

    private static let remoteHookFilesystemEnvironmentKeys: Set<String> =
        remoteHookRoutingEnvironmentKeys.union([
            "HOME", "CMUX_BUNDLED_CLI_PATH", "CODEX_HOME", "GROK_HOME",
            "OPENCODE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "PI_CONFIG_DIR",
            "CAMPFIRE_CODING_AGENT_DIR", "KIRO_HOME", "HERMES_HOME",
            "COPILOT_HOME", "CODEBUDDY_CONFIG_DIR", "QODER_CONFIG_DIR",
            "KIMI_SHARE_DIR", "KIMI_CODE_HOME",
        ])

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
        if method != "surface.resume.set", !Self.remoteHookMethods.contains(method),
           let key = firstKey(in: params, matching: Self.commandKeys) {
            return .deny(reason: "parameter '\(key)' is not permitted through a remote relay")
        }
        if Self.remoteHookMethods.contains(method),
           let reason = remoteHookDenialReason(method: method, params: params) {
            return .deny(reason: reason)
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

    private func remoteHookDenialReason(
        method: String,
        params: [String: Any]
    ) -> String? {
        guard let workspaceID = params["workspace_id"] as? String,
              UUID(uuidString: workspaceID) != nil,
              let surfaceID = params["surface_id"] as? String,
              UUID(uuidString: surfaceID) != nil else {
            return "remote hook requests require explicit workspace_id and surface_id selectors"
        }

        switch method {
        case "hooks.invoke", "hooks.invoke.begin":
            guard let arguments = params["arguments"] as? [String],
                  remoteHookArgumentsAreAllowed(arguments) else {
                return "remote hook arguments are invalid"
            }
            guard remoteHookEnvironmentIsAllowed(
                params["environment"],
                filesystemBridge: arguments.first?.hasPrefix("__remote-") == true
            ) else {
                return "remote hook environment is invalid"
            }
            if method == "hooks.invoke" {
                guard let encoded = params["stdin_base64"] as? String,
                      encoded.utf8.count <= 4 * 1_024 + 16,
                      let input = Data(base64Encoded: encoded),
                      input.count <= 3 * 1_024 else {
                    return "remote hook payload is invalid"
                }
            }
        case "hooks.invoke.append":
            guard remoteHookTransferIDIsValid(params["transfer_id"]),
                  let encoded = params["chunk_base64"] as? String,
                  encoded.utf8.count <= 8 * 1_024 + 16,
                  let chunk = Data(base64Encoded: encoded),
                  !chunk.isEmpty,
                  chunk.count <= 6 * 1_024 else {
                return "remote hook transfer chunk is invalid"
            }
        case "hooks.invoke.cancel", "hooks.invoke.execute":
            guard remoteHookTransferIDIsValid(params["transfer_id"]) else {
                return "remote hook transfer id is invalid"
            }
        default:
            return "remote hook method is invalid"
        }
        return nil
    }

    private func remoteHookArgumentsAreAllowed(_ arguments: [String]) -> Bool {
        guard !arguments.isEmpty,
              arguments.count <= 32,
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4_096 }),
              let first = arguments.first?.lowercased() else {
            return false
        }
        if first.hasPrefix("__remote-") {
            switch first {
            case "__remote-catalog": return arguments.count == 1
            case "__remote-describe": return arguments.count == 2
            case "__remote-configure": return arguments.count == 1
            default: return false
            }
        }
        let prohibitedCommands: Set<String> = ["install", "setup", "uninstall"]
        guard !prohibitedCommands.contains(first), arguments.count >= 2 else {
            return false
        }
        let prohibitedActions: Set<String> = [
            "install", "uninstall", "setup", "remove", "install-hooks",
            "uninstall-hooks",
        ]
        return !prohibitedActions.contains(arguments[1].lowercased())
    }

    private func remoteHookEnvironmentIsAllowed(
        _ rawEnvironment: Any?,
        filesystemBridge: Bool
    ) -> Bool {
        guard let environment = rawEnvironment as? [String: String],
              environment.count <= 32 else {
            return false
        }
        let allowed = filesystemBridge
            ? Self.remoteHookFilesystemEnvironmentKeys
            : Self.remoteHookRoutingEnvironmentKeys
        var totalBytes = 0
        for (key, value) in environment {
            guard allowed.contains(key),
                  !key.contains("\0"), !value.contains("\0"),
                  key.utf8.count <= 128, value.utf8.count <= 2 * 1_024 else {
                return false
            }
            totalBytes += key.utf8.count + value.utf8.count
            guard totalBytes <= 4 * 1_024 else { return false }
        }
        return true
    }

    private func remoteHookTransferIDIsValid(_ rawValue: Any?) -> Bool {
        guard let value = rawValue as? String else { return false }
        let components = value.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
              let slot = Int(components[0]),
              (0 ..< 4).contains(slot),
              let uuid = UUID(uuidString: String(components[1])) else {
            return false
        }
        return uuid.uuidString == components[1].uppercased()
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
