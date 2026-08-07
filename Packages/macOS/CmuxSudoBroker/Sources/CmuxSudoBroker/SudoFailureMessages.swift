/// Localized diagnostics persisted when the broker fails a request.
public struct SudoFailureMessages: Sendable, Equatable {
    /// Guidance shown when Touch ID is absent from sudo's PAM policy.
    public let pamTidUnavailable: String

    /// The diagnostic for a request that expired before approval.
    public let approvalTimedOut: String

    /// The diagnostic for an interrupted approved execution.
    public let executionInterrupted: String

    /// Creates the localized broker failure messages.
    public init(pamTidUnavailable: String, approvalTimedOut: String, executionInterrupted: String) {
        self.pamTidUnavailable = pamTidUnavailable
        self.approvalTimedOut = approvalTimedOut
        self.executionInterrupted = executionInterrupted
    }
}

