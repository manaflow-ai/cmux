import Foundation

/// Recognizes the bounded launch evidence emitted by `sr codex` and builds its
/// explicit resume argv without trusting environment-provided shell text.
public struct SubrouterCodexResumeRouting: Sendable, Equatable {
    /// The metadata marker emitted by Subrouter for routed Codex children.
    public static let environmentKey = "SUBROUTER_CODEX_RESUME_COMMAND"

    /// Wrapper-attested copy of the marker bound to the current Codex argv.
    public static let launchBoundEnvironmentKey = "CMUX_AGENT_LAUNCH_SUBROUTER_CODEX_RESUME_COMMAND"

    private static let expectedMarkerTokens = [
        ["sr", "codex", "resume"],
        ["subrouter", "codex", "resume"],
        ["cx", "codex", "resume"],
    ]

    private static let routingEnvironmentLimits = [
        "SUBROUTER_CODEX_ACCOUNT_ID": 256,
        "SUBROUTER_CODEX_BASE_URL": 2048,
        "SUBROUTER_CODEX_BIN": 4096,
        "SUBROUTER_CODEX_SERVER": 256,
        "SUBROUTER_CODEX_USER_EMAIL": 320,
    ]

    /// Creates a Subrouter Codex resume router.
    public init() {}

    /// Returns the canonical marker when the captured environment contains the
    /// exact supported command, or `nil` for absent or untrusted values.
    public func capturedMarker(in environment: [String: String]?) -> String? {
        guard let rawValue = environment?[Self.environmentKey] else {
            return nil
        }
        let tokens = rawValue.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard Self.expectedMarkerTokens.contains(tokens) else { return nil }
        return tokens.joined(separator: " ")
    }

    /// Returns bounded, non-secret Subrouter routing inputs that may accompany
    /// a trusted resume marker through structured restore metadata.
    public func capturedRoutingEnvironment(in environment: [String: String]?) -> [String: String] {
        guard let environment else { return [:] }
        var selected: [String: String] = [:]
        for key in Self.routingEnvironmentLimits.keys.sorted() {
            guard let value = sanitizedRoutingValue(key: key, value: environment[key]) else {
                continue
            }
            selected[key] = value
        }
        return selected
    }

    /// Returns the trusted marker and its bounded routing inputs for durable
    /// hook capture, or an empty environment when the marker is absent.
    public func capturedEnvironment(in environment: [String: String]?) -> [String: String] {
        guard let marker = capturedMarker(in: environment) else { return [:] }
        var selected = capturedRoutingEnvironment(in: environment)
        selected[Self.environmentKey] = marker
        return selected
    }

    /// Builds the captured Subrouter launcher resume argv only when both the
    /// trusted marker and Codex routing config prove the routed invocation.
    public func resumeArguments(
        launcher: String?,
        sessionID: String,
        launchArguments: [String],
        environment: [String: String]?
    ) -> [String]? {
        let normalizedLauncher = launcher?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedLauncher == nil || normalizedLauncher == "codex",
              let marker = capturedMarker(in: environment),
              launchArgumentsContainSubrouterProvider(launchArguments) else {
            return nil
        }
        return marker.split(separator: " ").map(String.init) + [sessionID]
    }

    /// Retains a canonical, non-secret routing proof when prompt sanitization
    /// removes Subrouter's trailing injected config block from captured argv.
    public func retainingRoutingProof(
        in sanitizedArguments: [String],
        from capturedArguments: [String],
        launcher: String?,
        environment: [String: String]?
    ) -> [String] {
        guard resumeArguments(
            launcher: launcher,
            sessionID: "capture-routing-validation",
            launchArguments: capturedArguments,
            environment: environment
        ) != nil else {
            return sanitizedArguments
        }
        if launchArgumentsContainSubrouterProvider(sanitizedArguments) {
            return sanitizedArguments
        }

        var retained = sanitizedArguments
        let insertionIndex = retained.firstIndex(of: "--") ?? retained.endIndex
        retained.insert(contentsOf: ["-c", "model_provider=subrouter"], at: insertionIndex)
        return retained
    }

    func removingRoutingArguments(from arguments: [String]) -> [String] {
        var selected: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                selected.append(contentsOf: arguments[index...])
                break
            }
            if (argument == "-c" || argument == "--config"), index + 1 < arguments.count {
                if isSubrouterRoutingAssignment(arguments[index + 1]) {
                    index += 2
                    continue
                }
            }
            if ["-c=", "--config="].contains(where: { prefix in
                argument.hasPrefix(prefix)
                    && isSubrouterRoutingAssignment(String(argument.dropFirst(prefix.count)))
            }) {
                index += 1
                continue
            }
            selected.append(argument)
            index += 1
        }
        return selected
    }

    private func launchArgumentsContainSubrouterProvider(_ arguments: [String]) -> Bool {
        var effectiveProvider: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                break
            }
            if (argument == "-c" || argument == "--config"),
               index + 1 < arguments.count,
               let provider = modelProviderAssignment(in: arguments[index + 1]) {
                effectiveProvider = provider
                index += 2
                continue
            }
            for prefix in ["-c=", "--config="] where argument.hasPrefix(prefix) {
                if let provider = modelProviderAssignment(in: String(argument.dropFirst(prefix.count))) {
                    effectiveProvider = provider
                }
            }
            index += 1
        }
        return effectiveProvider == "subrouter"
    }

    private func modelProviderAssignment(in rawValue: String) -> String? {
        let parts = rawValue.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "model_provider" else {
            return nil
        }
        var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private func isSubrouterRoutingAssignment(_ rawValue: String) -> Bool {
        let parts = rawValue.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return key == "model_provider" || key.hasPrefix("model_providers.subrouter.")
    }

    private func sanitizedRoutingValue(key: String, value: String?) -> String? {
        guard let maximumByteCount = Self.routingEnvironmentLimits[key],
              let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumByteCount,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        guard key == "SUBROUTER_CODEX_BASE_URL" else { return trimmed }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              !components.path.lowercased().hasPrefix("/t/"),
              !components.percentEncodedPath.lowercased().hasPrefix("/t/") else {
            return nil
        }
        return trimmed
    }
}
