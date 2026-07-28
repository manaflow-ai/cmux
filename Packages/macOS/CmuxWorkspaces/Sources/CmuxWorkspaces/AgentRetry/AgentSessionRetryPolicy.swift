/// Fail-closed retry classification and bounded exponential backoff.
public struct AgentSessionRetryPolicy: Equatable, Sendable {
    /// The product retry policy: three attempts after 1, 2, and 4 seconds.
    public static let standard = AgentSessionRetryPolicy(
        maximumAttempts: 3,
        backoffSeconds: [1, 2, 4]
    )

    /// The maximum resume commands permitted for one continuously failing session.
    public let maximumAttempts: Int
    /// Delay before each retry, indexed by the zero-based completed-attempt count.
    public let backoffSeconds: [Double]

    /// Creates a bounded retry policy.
    ///
    /// - Parameters:
    ///   - maximumAttempts: A positive maximum number of resume commands.
    ///   - backoffSeconds: Nonnegative finite delays with at least one value per attempt.
    public init(maximumAttempts: Int, backoffSeconds: [Double]) {
        precondition(maximumAttempts > 0)
        precondition(backoffSeconds.count >= maximumAttempts)
        precondition(backoffSeconds.prefix(maximumAttempts).allSatisfy { $0.isFinite && $0 >= 0 })
        self.maximumAttempts = maximumAttempts
        self.backoffSeconds = backoffSeconds
    }

    /// Returns the next retry action after `completedAttempts` resume commands
    /// have already been launched for the same failed session.
    ///
    /// - Parameters:
    ///   - context: The authoritative opt-in, lifecycle, binding, and exit facts.
    ///   - completedAttempts: Resume commands already launched for this session.
    /// - Returns: The next retry, exhaustion, or rejection transition.
    public func decision(
        for context: AgentSessionRetryContext,
        completedAttempts: Int
    ) -> AgentSessionRetryDecision {
        guard context.isEnabled else { return .reject(.disabled) }
        guard context.hadActiveAgentSession else { return .reject(.inactiveSession) }
        guard context.hasManagedResumeBinding else { return .reject(.missingResumeBinding) }
        guard let exitCode = context.exitCode else { return .reject(.unknownExit) }
        guard exitCode != 0 else { return .reject(.successfulExit) }

        // Shells conventionally encode signal termination as 128 + signal.
        // Treat the entire portable signal range as intentional/ambiguous so
        // Ctrl-C, pane teardown, and explicit kills never resurrect an agent.
        guard !(128...192).contains(exitCode) else { return .reject(.signalExit) }

        let normalizedCompletedAttempts = max(0, completedAttempts)
        guard normalizedCompletedAttempts < maximumAttempts else {
            return .exhausted(maximumAttempts: maximumAttempts)
        }
        let attempt = normalizedCompletedAttempts + 1
        return .retry(
            attempt: attempt,
            maximumAttempts: maximumAttempts,
            delaySeconds: backoffSeconds[attempt - 1]
        )
    }
}
