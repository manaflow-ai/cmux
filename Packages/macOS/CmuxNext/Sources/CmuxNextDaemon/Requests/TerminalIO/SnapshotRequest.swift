/// One READY + history on the caller's snapshot attach of `surface`
/// (`terminal-snapshot-v1`). Fire-and-forget from the view.
public struct SnapshotRequestRequest: DaemonRequest {
    /// `SnapshotRequestResult`: whether a READY is coming.
    public struct Response: Decodable, Sendable, Equatable {
        public enum Status: String, Decodable, Sendable, Equatable {
            /// The viewer's next attach event is a READY snapshot.
            case accepted
            /// A snapshot is already pending and answers this request.
            case collapsed
            /// The viewer got a snapshot less than 500 ms ago; ask again after `retryAfterMs`.
            case snapshotThrottled = "snapshot_throttled"
        }

        public var status: Status
        public var retryAfterMs: UInt64?

        enum CodingKeys: String, CodingKey {
            case status
            case retryAfterMs = "retry_after_ms"
        }
    }

    public static let commandName: DaemonCommandName = "snapshot-request"
    public var surface: SurfaceID
    public var reason: SnapshotRequestReason
    /// The attach stream (`attach-streams-v1`) the READY is for; nil asks on the attach of this
    /// connection (one view per connection).
    public var stream: UInt16?

    public init(surface: SurfaceID, reason: SnapshotRequestReason, stream: UInt16? = nil) {
        self.surface = surface
        self.reason = reason
        self.stream = stream
    }
}
