import Foundation

/// Classifies persisted restore provenance without launching an agent.
public struct AgentRestoreRouteClassifier: Sendable {
    private static let claudePinnedEnvironmentKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CONFIG_DIR",
    ]

    /// Creates a stateless restore-route classifier.
    public init() {}

    /// Returns the direct, pooled, or pinned provenance encoded by a restore request.
    ///
    /// Explicit direct-mode requests remain direct. For managed restores, the
    /// classifier recognizes the same captured Codex and Claude Subrouter
    /// contracts used by ``AgentRestorePlanner`` and distinguishes an account
    /// selector from ambient process state.
    ///
    /// - Parameter request: Structured persisted restore request to inspect.
    /// - Returns: The route that the persisted request requires.
    public func route(for request: AgentRestoreRequest) -> AgentRestoreRoute {
        guard request.mode != .direct else { return .direct }
        let kind = normalized(request.kind)
        let environment = mergedEnvironment(for: request)
        guard isSubrouterRouted(
            kind: kind,
            arguments: request.preparedArguments ?? request.launchCommand?.arguments ?? [],
            environment: environment
        ) else {
            return .direct
        }
        return hasPinnedSelection(
            kind: kind,
            arguments: request.preparedArguments ?? request.launchCommand?.arguments ?? [],
            environment: environment
        ) ? .pinned : .pooled
    }

    private func mergedEnvironment(for request: AgentRestoreRequest) -> [String: String] {
        (request.launchCommand?.environment ?? [:]).merging(request.environment) { _, binding in
            binding
        }
    }

    private func isSubrouterRouted(
        kind: String,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if kind == "claude" {
            return isKnownSubrouterURL(environment["ANTHROPIC_BASE_URL"])
        }
        guard kind == "codex" else { return false }
        return codexConfigValues(arguments).contains { value in
            value == "model_provider=\"subrouter\""
                || value == "model_provider='subrouter'"
                || value == "model_provider=subrouter"
                || value.hasPrefix("model_providers.subrouter.")
        }
    }

    private func codexConfigValues(_ arguments: [String]) -> [String] {
        var values: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-c" || argument == "--config" {
                if index + 1 < arguments.count {
                    values.append(normalized(arguments[index + 1]))
                    index += 1
                }
            } else if argument.hasPrefix("-c=") {
                values.append(normalized(String(argument.dropFirst(3))))
            } else if argument.hasPrefix("--config=") {
                values.append(normalized(String(argument.dropFirst(9))))
            }
            index += 1
        }
        return values
    }

    private func isKnownSubrouterURL(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              let host = URLComponents(string: value)?.host?.lowercased() else {
            return false
        }
        let firstLabel = host.split(separator: ".", maxSplits: 1).first.map(String.init)
        return host == "sr.cmux.com"
            || host == "staging.sr.cmux.com"
            || firstLabel == "subrouter"
            || firstLabel?.hasPrefix("subrouter-") == true
            || host.hasSuffix(".subrouter")
    }

    private func hasPinnedSelection(
        kind: String,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if kind == "claude" {
            return Self.claudePinnedEnvironmentKeys.contains {
                nonempty(environment[$0])
            }
        }
        guard kind == "codex" else { return false }
        if nonempty(environment["CODEX_HOME"]) {
            return true
        }
        return codexConfigValues(arguments).contains {
            $0.contains("x-subrouter-account-id")
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nonempty(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
