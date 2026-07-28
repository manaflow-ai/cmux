/// The authoritative facts available when an agent command returns to its shell.
public struct AgentSessionRetryContext: Equatable, Sendable {
    /// Whether the user opted into automatic retry.
    public let isEnabled: Bool
    /// Whether managed hooks observed an active agent during this command.
    public let hadActiveAgentSession: Bool
    /// Whether cmux retained a managed resume binding for the active session.
    public let hasManagedResumeBinding: Bool
    /// The shell-reported exit status, or `nil` when shell integration omitted it.
    public let exitCode: Int?

    /// Creates the facts used to classify one command termination.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether the user opted into automatic retry.
    ///   - hadActiveAgentSession: Whether managed hooks observed an active agent.
    ///   - hasManagedResumeBinding: Whether the active session can be resumed.
    ///   - exitCode: The shell-reported exit status, or `nil` when unavailable.
    public init(
        isEnabled: Bool,
        hadActiveAgentSession: Bool,
        hasManagedResumeBinding: Bool,
        exitCode: Int?
    ) {
        self.isEnabled = isEnabled
        self.hadActiveAgentSession = hadActiveAgentSession
        self.hasManagedResumeBinding = hasManagedResumeBinding
        self.exitCode = exitCode
    }
}

/// Why automatic retry deliberately declined a command termination.
public enum AgentSessionRetryRejection: Equatable, Sendable {
    /// Automatic retry is disabled.
    case disabled
    /// No managed agent was active when the command ended.
    case inactiveSession
    /// The active session has no authoritative managed resume binding.
    case missingResumeBinding
    /// Shell integration did not report an exit status.
    case unknownExit
    /// The command completed successfully.
    case successfulExit
    /// The exit status is signal-like and may represent an intentional stop.
    case signalExit
}

/// The next state transition selected by ``AgentSessionRetryPolicy``.
public enum AgentSessionRetryDecision: Equatable, Sendable {
    /// Schedule the numbered retry after the specified delay.
    case retry(attempt: Int, maximumAttempts: Int, delaySeconds: Double)
    /// Surface exhaustion because every permitted retry was already launched.
    case exhausted(maximumAttempts: Int)
    /// Decline retry for a fail-closed classification reason.
    case reject(AgentSessionRetryRejection)
}

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
