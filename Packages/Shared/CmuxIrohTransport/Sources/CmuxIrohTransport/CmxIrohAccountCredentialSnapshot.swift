/// One authenticated account and credential pair captured atomically.
///
/// Platform auth coordinators map their native session snapshot into this
/// transport-owned value so account pinning and exactly-once rejection
/// recovery stay identical on macOS and iOS.
public struct CmxIrohAccountCredentialSnapshot: Sendable {
    /// The authenticated account that owns `credentials`.
    public let accountID: String

    /// The access and refresh credentials captured for `accountID`.
    public let credentials: CmxIrohBrokerCredentials

    /// Creates an account-pinned credential snapshot.
    ///
    /// - Parameters:
    ///   - accountID: The authenticated account identifier.
    ///   - credentials: The atomically captured access/refresh pair.
    public init(
        accountID: String,
        credentials: CmxIrohBrokerCredentials
    ) {
        self.accountID = accountID
        self.credentials = credentials
    }
}
