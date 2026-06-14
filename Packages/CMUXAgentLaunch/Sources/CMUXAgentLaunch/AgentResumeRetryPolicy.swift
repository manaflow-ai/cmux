import Foundation

/// Describes when an agent resume command should be retried after a transient startup failure.
///
/// The policy is intentionally narrow: callers opt in for known retryable agents, and shell
/// launchers only retry failures that exit inside a short startup window. Callers that already have
/// failed process output can use ``matches(output:)`` to check the same known retryable signatures.
public struct AgentResumeRetryPolicy: Sendable, Equatable {
    /// The maximum number of retries after the first failed launch attempt.
    public let maximumRetries: Int

    /// The delay between retry attempts, before the per-process stagger is added.
    public let delaySeconds: Double

    /// The startup window, in whole seconds, during which a failed shell launch may be retried.
    public let startupFailureWindowSeconds: Int

    /// Case-insensitive output fragments that identify a retryable transient failure.
    public let outputNeedles: [String]

    /// Creates a retry policy for a generated resume launcher.
    ///
    /// - Parameters:
    ///   - maximumRetries: The maximum number of retries after the first failed launch attempt.
    ///   - delaySeconds: The delay between retry attempts.
    ///   - outputNeedles: Case-insensitive output fragments that identify retryable failures.
    ///   - startupFailureWindowSeconds: The shell-launch startup window that allows retrying a
    ///     failed attempt without recording an interactive transcript.
    public init(
        maximumRetries: Int,
        delaySeconds: Double,
        outputNeedles: [String],
        startupFailureWindowSeconds: Int = 5
    ) {
        self.maximumRetries = max(0, maximumRetries)
        self.delaySeconds = max(0, delaySeconds)
        self.startupFailureWindowSeconds = max(0, startupFailureWindowSeconds)
        self.outputNeedles = outputNeedles
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// A policy that never retries.
    public static let disabled = AgentResumeRetryPolicy(
        maximumRetries: 0,
        delaySeconds: 0,
        outputNeedles: [],
        startupFailureWindowSeconds: 0
    )

    /// Retries Codex's transient shared-state SQLite lock failure.
    public static let codexStateDatabaseLock = AgentResumeRetryPolicy(
        maximumRetries: 3,
        delaySeconds: 0.25,
        outputNeedles: [
            "database is locked",
            "another Codex process is using its local data",
        ],
        startupFailureWindowSeconds: 5
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
    /// - Returns: `true` when `output` contains a retryable signature; otherwise `false`.
    public func matches(output: String) -> Bool {
        guard isEnabled else { return false }
        let lowercasedOutput = output.lowercased()
        return outputNeedles.contains { lowercasedOutput.contains($0.lowercased()) }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}
