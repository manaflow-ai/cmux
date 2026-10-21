import Foundation

/// The trust result for provider declarations captured from a Codex launch.
///
/// Restore code may route a session only for ``provider(_:)`` with the
/// expected value. Missing declarations remain ordinary Codex launches, and
/// conflicting declarations are deliberately rejected as ambiguous.
public enum SubrouterCodexProviderEvidence: Equatable, Sendable {
    /// No provider declaration was present in the captured invocation.
    case absent

    /// Exactly one provider declaration was present.
    case provider(String)

    /// More than one provider declaration, or a non-Codex invocation, was
    /// observed and cannot safely be used for routing.
    case ambiguous
}

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

    /// Environment keys whose presence and absence are owned by a proven
    /// routed launch record during restore.
    public static let restoreOwnedEnvironmentKeys: Set<String> = Set(routingEnvironmentLimits.keys)
        .union([
            environmentKey,
            launchBoundEnvironmentKey,
            "CMUX_CUSTOM_CODEX_PATH",
        ])

    /// Creates a Subrouter Codex resume router.
    public init() {}

    /// Returns the canonical marker when the captured environment contains the
    /// exact supported command, or `nil` for absent or untrusted values.
    public func capturedMarker(in environment: [String: String]?) -> String? {
        canonicalMarker(environment?[Self.environmentKey])
    }

    private func capturedLaunchBoundMarker(in environment: [String: String]?) -> String? {
        guard let marker = capturedMarker(in: environment),
              canonicalMarker(environment?[Self.launchBoundEnvironmentKey]) == marker else {
            return nil
        }
        return marker
    }

    private func canonicalMarker(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
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

    /// Returns the real Codex executable retained behind the managed wrapper.
    /// An already captured custom path takes precedence over Subrouter's child
    /// binary, which may itself be the wrapper after an earlier restore.
    public func preferredCustomCodexExecutable(
        in environment: [String: String]?,
        fallbackExecutable: String?,
        wrapperShim: String
    ) -> String? {
        let candidates = [
            sanitizedPathValue(environment?["CMUX_CUSTOM_CODEX_PATH"]),
            sanitizedPathValue(fallbackExecutable),
            sanitizedPathValue(environment?["SUBROUTER_CODEX_BIN"]),
        ]
        return candidates.compactMap { $0 }.first { $0 != wrapperShim }
    }

    /// Returns the trusted marker and its bounded routing inputs for durable
    /// hook capture, or an empty environment when the marker is absent.
    public func capturedEnvironment(in environment: [String: String]?) -> [String: String] {
        guard let marker = capturedLaunchBoundMarker(in: environment) else { return [:] }
        var selected = capturedRoutingEnvironment(in: environment)
        selected[Self.environmentKey] = marker
        selected[Self.launchBoundEnvironmentKey] = marker
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
              let marker = capturedLaunchBoundMarker(in: environment),
              launchArgumentsContainSubrouterProvider(
                  launchArguments,
                  launcher: normalizedLauncher
              ) else {
            return nil
        }
        return marker.split(separator: " ").map(String.init) + [sessionID]
    }

    /// Returns whether captured Codex arguments explicitly select Subrouter.
    ///
    /// Older cmux bindings can retain the provider configuration without the
    /// wrapper's resume marker. They still need the dummy credential exported
    /// before Codex starts; this check is limited to the non-secret provider
    /// selection in the captured argv.
    public func usesSubrouterProvider(in launchArguments: [String]) -> Bool {
        providerEvidence(in: launchArguments) == .provider("subrouter")
    }

    /// Legacy surface bindings may retain only their canonical shell command
    /// after trust sanitization. Preserve the non-secret provider proof from
    /// that command so a valid Subrouter checkpoint is still resumable.
    public func usesSubrouterProvider(in shellCommand: String?) -> Bool {
        guard let shellCommand,
              let tokens = shellCommandTokens(shellCommand),
              !tokens.isEmpty else { return false }
        let executable = URL(fileURLWithPath: tokens[0]).lastPathComponent.lowercased()
        let isCodexCommand = executable == "codex" ||
            (executable == "sr" && tokens.dropFirst().first == "codex") ||
            (executable == "subrouter" && tokens.dropFirst().first == "codex")
        guard isCodexCommand else { return false }
        return providerEvidence(in: tokens) == .provider("subrouter")
    }

    /// Returns the provider evidence in a captured argv. `ambiguous` means
    /// that the record explicitly names more than one provider and must never
    /// be upgraded into a routed restore.
    public func providerEvidence(in launchArguments: [String]) -> SubrouterCodexProviderEvidence {
        guard isCodexInvocation(launchArguments) else { return .ambiguous }
        return providerEvidenceFromAssignments(in: launchArguments)
    }

    /// Returns provider evidence using a captured managed launcher kind.
    ///
    /// A managed Codex launch may retain a custom executable path (for example
    /// `/opt/company/codex`) whose basename is not `codex`. The launcher kind
    /// is durable identity evidence for that case, while all provider
    /// assignments still have to pass the same ambiguity checks.
    public func providerEvidence(
        in launchArguments: [String],
        launcher: String?
    ) -> SubrouterCodexProviderEvidence {
        let normalizedLauncher = launcher?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalizedLauncher == nil || normalizedLauncher == "codex" else {
            return .ambiguous
        }
        if normalizedLauncher == "codex" {
            return providerEvidenceFromAssignments(in: launchArguments)
        }
        return providerEvidence(in: launchArguments)
    }

    /// Returns provider evidence from a canonical legacy shell command.
    public func providerEvidence(in shellCommand: String?) -> SubrouterCodexProviderEvidence {
        guard let shellCommand else { return .absent }
        guard !shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .absent
        }
        guard let tokens = shellCommandTokens(shellCommand), !tokens.isEmpty else {
            // A non-empty legacy command that cannot be tokenized is damaged
            // evidence, not proof that no provider was recorded.
            return .ambiguous
        }
        let executable = URL(fileURLWithPath: tokens[0]).lastPathComponent.lowercased()
        let isCodexCommand = executable == "codex" ||
            (executable == "sr" && tokens.dropFirst().first == "codex") ||
            (executable == "subrouter" && tokens.dropFirst().first == "codex")
        guard isCodexCommand else { return .ambiguous }
        return providerEvidenceFromAssignments(in: tokens)
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
        if launchArgumentsContainSubrouterProvider(sanitizedArguments, launcher: launcher) {
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

    /// Removes only actual pre-terminator Subrouter configuration options from
    /// an argv intended for a public status surface. Prompt text and the literal
    /// `--` suffix remain byte-for-byte intact.
    public func removingPrivateRoutingArguments(from arguments: [String]) -> [String] {
        var selected: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                selected.append(contentsOf: arguments[index...])
                break
            }
            if (argument == "-c" || argument == "--config"), index + 1 < arguments.count,
               isPrivateSubrouterRoutingAssignment(arguments[index + 1]) {
                index += 2
                continue
            }
            if ["-c=", "--config="].contains(where: { prefix in
                argument.hasPrefix(prefix)
                    && isPrivateSubrouterRoutingAssignment(String(argument.dropFirst(prefix.count)))
            }) {
                index += 1
                continue
            }
            selected.append(argument)
            index += 1
        }
        return selected
    }

    private func launchArgumentsContainSubrouterProvider(
        _ arguments: [String],
        launcher: String?
    ) -> Bool {
        providerEvidence(in: arguments, launcher: launcher) == .provider("subrouter")
    }

    private func isCodexInvocation(_ arguments: [String]) -> Bool {
        guard let first = arguments.first else { return false }
        let executable = URL(fileURLWithPath: first).lastPathComponent.lowercased()
        return executable == "codex" ||
            (executable == "sr" && arguments.dropFirst().first == "codex") ||
            (executable == "subrouter" && arguments.dropFirst().first == "codex")
    }

    private func providerEvidenceFromAssignments(in arguments: [String]) -> SubrouterCodexProviderEvidence {
        var observedProviders: Set<String> = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                break
            }
            if (argument == "-c" || argument == "--config"),
               index + 1 < arguments.count {
                let value = arguments[index + 1]
                if let provider = modelProviderAssignment(in: value) {
                    observedProviders.insert(provider)
                } else if looksLikeModelProviderAssignment(value) {
                    return .ambiguous
                }
                index += 2
                continue
            }
            for prefix in ["-c=", "--config="] where argument.hasPrefix(prefix) {
                let value = String(argument.dropFirst(prefix.count))
                if let provider = modelProviderAssignment(in: value) {
                    observedProviders.insert(provider)
                } else if looksLikeModelProviderAssignment(value) {
                    return .ambiguous
                }
            }
            index += 1
        }
        // Multiple provider declarations are only safe when they agree. A
        // stale or hand-edited record that mixes Subrouter with another
        // provider must not be upgraded into routed restore evidence.
        guard !observedProviders.isEmpty else { return .absent }
        guard observedProviders.count == 1, let provider = observedProviders.first else {
            return .ambiguous
        }
        return .provider(provider)
    }

    private func looksLikeModelProviderAssignment(_ rawValue: String) -> Bool {
        let parts = rawValue.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count == 2 &&
            parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "model_provider"
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
        } else if value.first == "\"" || value.first == "'" ||
                    value.last == "\"" || value.last == "'" {
            return nil
        }
        return value
    }

    /// Tokenizes the small, canonical command form persisted for legacy
    /// restores. Any shell operator, expansion, or unterminated quote makes
    /// the evidence ambiguous and therefore unusable for routing.
    private func shellCommandTokens(_ command: String) -> [String]? {
        var tokens: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        for character in command {
            if escaped {
                token.append(character)
                escaped = false
                continue
            }
            if character == "\\" && quote != "'" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil } else { token.append(character) }
                continue
            }
            if character == "'" || character == "\"" {
                quote = character
            } else if character.isWhitespace {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else if ";|&<>$()`".contains(character) {
                return nil
            } else {
                token.append(character)
            }
        }
        guard !escaped, quote == nil else { return nil }
        if !token.isEmpty { tokens.append(token) }
        return tokens
    }

    private func isSubrouterRoutingAssignment(_ rawValue: String) -> Bool {
        let parts = rawValue.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return key == "model_provider" || key.hasPrefix("model_providers.subrouter.")
    }

    private func isPrivateSubrouterRoutingAssignment(_ rawValue: String) -> Bool {
        if modelProviderAssignment(in: rawValue) == "subrouter" {
            return true
        }
        let parts = rawValue.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("model_providers.subrouter.")
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

    private func sanitizedPathValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 4096,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return trimmed
    }
}
