/// Tracks the account-level transition between missing and trusted phone keys.
public struct PhonePushEncryptionUnavailableReporter: Sendable {
    private var reportedAccountIDs: Set<String> = []

    /// Creates an empty reporter with no accounts recorded.
    public init() {}

    /// Records a missing-key report when this account has not reported one in its current state.
    ///
    /// - Parameter accountID: The authenticated account whose phone key is unavailable.
    /// - Returns: `true` only for the first report after the account's last trusted key.
    public mutating func shouldReportUnavailable(for accountID: String) -> Bool {
        reportedAccountIDs.insert(accountID).inserted
    }

    /// Clears the missing-key report latch after a trusted recipient is found.
    ///
    /// - Parameter accountID: The authenticated account whose trusted phone key is available.
    public mutating func noteTrustedRecipientAvailable(for accountID: String) {
        reportedAccountIDs.remove(accountID)
    }
}
