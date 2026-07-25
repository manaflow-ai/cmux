import Foundation

/// Defines which agent hook events may use asynchronous queued delivery.
///
/// Lifecycle and status events are safe for every agent because their output
/// does not affect the agent's next decision. Wrapper-specific auxiliary
/// events remain explicitly scoped to the wrappers that own their contracts.
public struct AgentHookDeliveryPolicy: Sendable {
    /// The largest payload accepted by the local delivery queue.
    public static let maximumPayloadBytes = 64 * 1_024

    /// The maximum time a queued hook waits for the app to acknowledge admission.
    public static let admissionResponseTimeoutSeconds: TimeInterval = 0.5

    /// The timeout declared to agent runtimes for queued hook processes.
    public static let declaredTimeoutSeconds = 5

    /// The declared queued-hook timeout in milliseconds for runtimes such as Codex.
    public static let declaredTimeoutMilliseconds = declaredTimeoutSeconds * 1_000

    /// Current and historical queued-hook timeouts recognized during launch replay.
    ///
    /// Older cmux builds generated 3- and 10-second Codex hook timeouts. Replay
    /// must continue to strip those cmux-owned prefixes as well as the current
    /// 5-second form.
    public static let recognizedTimeoutMilliseconds: Set<Int> = [
        declaredTimeoutMilliseconds,
        3_000,
        10_000,
    ]

    private static let genericQueuedSubcommands: Set<String> = [
        "session-start",
        "prompt-submit",
        "stop",
        "notification",
        "agent-response",
        "approval-response",
        "shell-exec",
        "shell-done",
        "session-end",
        "session-finalize",
    ]

    private static let auxiliaryQueuedSubcommands: [String: Set<String>] = [
        "claude": ["pre-tool-use", "push-notification", "feed"],
        "codex": ["pre-tool-use", "post-tool-use"],
    ]

    /// Creates the shared queued-delivery policy.
    public init() {}

    /// Returns the environment key used to preserve an agent process identity.
    ///
    /// - Parameter agentName: The agent's normalized or display name.
    /// - Returns: An ASCII environment variable such as `CMUX_CLAUDE_PID`.
    public func pidEnvironmentVariable(agentName: String) -> String {
        let component = agentName.uppercased().replacingOccurrences(
            of: "[^A-Z0-9]",
            with: "_",
            options: .regularExpression
        )
        return "CMUX_\(component)_PID"
    }

    /// Reports whether an agent event is safe to acknowledge before delivery.
    ///
    /// - Parameters:
    ///   - agent: The agent integration name.
    ///   - subcommand: The cmux hook subcommand.
    /// - Returns: `true` only for non-decision lifecycle, status, or known
    ///   wrapper-owned auxiliary events.
    public func supportsQueuedDelivery(agent: String, subcommand: String) -> Bool {
        let normalizedAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSubcommand = subcommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedAgent.isEmpty,
              normalizedAgent.utf8.count <= 128,
              !normalizedAgent.contains("\0"),
              !normalizedSubcommand.isEmpty,
              normalizedSubcommand.utf8.count <= 64,
              !normalizedSubcommand.contains("\0") else {
            return false
        }
        if Self.genericQueuedSubcommands.contains(normalizedSubcommand) {
            return true
        }
        return Self.auxiliaryQueuedSubcommands[normalizedAgent]?.contains(normalizedSubcommand) == true
    }
}
