/// One authenticated account and credential pair captured atomically.
///
/// Platform auth coordinators map their native session snapshot into this
/// transport-owned value so account pinning and exactly-once rejection
/// recovery stay identical on macOS and iOS.
public struct CmxIrohAccountCredentialSnapshot: Sendable {
    public let accountID: String
    public let credentials: CmxIrohBrokerCredentials

    public init(
        accountID: String,
        credentials: CmxIrohBrokerCredentials
    ) {
        self.accountID = accountID
        self.credentials = credentials
    }
}
