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
            return nonempty(environment["ANTHROPIC_BASE_URL"])
        }
        guard kind == "codex" else { return false }
        return normalizedArguments(arguments).contains { argument in
            argument.contains("model_provider=\"subrouter\"")
                || argument.contains("model_provider='subrouter'")
                || argument.contains("model_provider=subrouter")
                || argument.contains("model_providers.subrouter.")
                || argument.contains("openai_base_url=")
        }
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
        return normalizedArguments(arguments).contains {
            $0.contains("x-subrouter-account-id")
        }
    }

    private func normalizedArguments(_ arguments: [String]) -> [String] {
        arguments.map { normalized($0) }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func nonempty(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
