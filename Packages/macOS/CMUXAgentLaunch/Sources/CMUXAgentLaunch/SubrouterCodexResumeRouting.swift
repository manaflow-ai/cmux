import Foundation

/// Recognizes the bounded launch evidence emitted by `sr codex` and builds its
/// explicit resume argv without trusting environment-provided shell text.
public struct SubrouterCodexResumeRouting: Sendable, Equatable {
    /// The metadata marker emitted by Subrouter for routed Codex children.
    public static let environmentKey = "SUBROUTER_CODEX_RESUME_COMMAND"

    private static let expectedMarkerTokens = [
        ["sr", "codex", "resume"],
        ["subrouter", "codex", "resume"],
        ["cx", "codex", "resume"],
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

    private func launchArgumentsContainSubrouterProvider(_ arguments: [String]) -> Bool {
        for (index, argument) in arguments.enumerated() {
            if (argument == "-c" || argument == "--config"),
               index + 1 < arguments.count,
               isSubrouterProviderAssignment(arguments[index + 1]) {
                return true
            }
            for prefix in ["-c=", "--config="] where argument.hasPrefix(prefix) {
                if isSubrouterProviderAssignment(String(argument.dropFirst(prefix.count))) {
                    return true
                }
            }
        }
        return false
    }

    private func isSubrouterProviderAssignment(_ rawValue: String) -> Bool {
        let parts = rawValue.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "model_provider" else {
            return false
        }
        var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        return value == "subrouter"
    }
}
