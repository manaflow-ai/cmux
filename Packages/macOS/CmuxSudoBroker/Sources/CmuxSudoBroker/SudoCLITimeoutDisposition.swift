/// The CLI diagnostic category chosen when its request deadline expires.
public enum SudoCLITimeoutDisposition: Sendable, Equatable {
    /// No approval transition occurred before the deadline.
    case pendingApproval

    /// Approval occurred, but the independently bounded execution is unfinished.
    case approvedExecution

    /// Resolves the diagnostic from durable broker state.
    ///
    /// - Parameter phase: The last state observed by the CLI.
    /// - Returns: The timeout category shown to the user.
    public static func resolve(phase: SudoRequestPhase?) -> SudoCLITimeoutDisposition {
        // Legacy CLI always blamed a still-pending approval.
        .pendingApproval
    }
}

