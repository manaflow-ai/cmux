/// One idempotent batch of Cloud notification read acknowledgements.
public struct CloudNotificationSyncPendingAck: Codable, Equatable, Sendable {
    public var key: String
    public var ids: [String]
}
