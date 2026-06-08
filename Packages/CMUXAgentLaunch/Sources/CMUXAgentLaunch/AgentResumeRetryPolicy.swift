import Foundation

/// Describes when an agent resume command should be retried after a transient failure.
///
/// The policy is intentionally narrow: callers opt in for known retryable agents, and the launcher
/// retries only when the failed process output contains one of ``outputNeedles``. Non-matching
/// failures still fall through to the post-agent shell without another attempt.
public struct AgentResumeRetryPolicy: Sendable, Equatable {
    /// The maximum number of retries after the first failed launch attempt.
    public let maximumRetries: Int

    /// The delay between retry attempts, before the per-process stagger is added.
    public let delaySeconds: Double

    /// Case-insensitive output fragments that identify a retryable transient failure.
    public let outputNeedles: [String]

    /// Creates a retry policy for a generated resume launcher.
    ///
    /// - Parameters:
    ///   - maximumRetries: The maximum number of retries after the first failed launch attempt.
    ///   - delaySeconds: The delay between retry attempts.
    ///   - outputNeedles: Case-insensitive output fragments that identify retryable failures.
    public init(maximumRetries: Int, delaySeconds: Double, outputNeedles: [String]) {
        self.maximumRetries = max(0, maximumRetries)
        self.delaySeconds = max(0, delaySeconds)
        self.outputNeedles = outputNeedles
    }

    /// A policy that never retries.
    public static let disabled = AgentResumeRetryPolicy(
        maximumRetries: 0,
        delaySeconds: 0,
        outputNeedles: []
    )

    /// Retries Codex's transient shared-state SQLite lock failure.
    public static let codexStateDatabaseLock = AgentResumeRetryPolicy(
        maximumRetries: 3,
        delaySeconds: 0.25,
        outputNeedles: [
            "database is locked",
            "another Codex process is using its local data",
        ]
    )

    /// Returns `true` when this policy can retry at least one failure.
    public var isEnabled: Bool {
        maximumRetries > 0 && !outputNeedles.isEmpty
    }

    /// Chooses the retry policy for a captured agent kind and launcher.
    ///
    /// - Parameters:
    ///   - agentKind: The raw agent kind, such as `"codex"`.
    ///   - launcher: The captured launcher name, such as `"codexTeams"`.
    /// - Returns: ``codexStateDatabaseLock`` for Codex launches; otherwise ``disabled``.
    public static func policy(agentKind: String?, launcher: String? = nil) -> AgentResumeRetryPolicy {
        if normalized(agentKind) == "codex" || normalized(launcher) == "codexteams" {
            return .codexStateDatabaseLock
        }
        return .disabled
    }

    /// Returns `true` when process output contains a retryable signature.
    ///
    /// - Parameter output: Combined stdout/stderr from the failed attempt.
    public func matches(output: String) -> Bool {
        guard isEnabled else { return false }
        let lowercasedOutput = output.lowercased()
        return outputNeedles.contains { lowercasedOutput.contains($0.lowercased()) }
    }

    var shellGrepPattern: String {
        outputNeedles
            .filter { !$0.isEmpty }
            .map(Self.extendedGrepEscaped)
            .joined(separator: "|")
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    private static func extendedGrepEscaped(_ value: String) -> String {
        let specialCharacters = #"[]\.^$*+?{}()|"#
        var result = ""
        for character in value {
            if specialCharacters.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}
