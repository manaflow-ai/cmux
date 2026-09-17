/// One idempotent batch of Cloud notification read acknowledgements.
struct CloudNotificationSyncPendingAck: Codable, Equatable, Sendable {
    var key: String
    var ids: [String]
}
