/// One idempotent batch of Cloud notification read acknowledgements.
public struct CloudNotificationSyncPendingAck: Codable, Equatable, Sendable {
    public var key: String
    public var ids: [String]

    public init(
        key: String,
        ids: [String]
    ) {
        self.key = key
        self.ids = ids
    }
}
