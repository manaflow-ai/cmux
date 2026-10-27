/// One READY + history on the caller's snapshot attach of `surface`
/// (`terminal-snapshot-v1`). Fire-and-forget from the view.
public struct SnapshotRequestRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let commandName: DaemonCommandName = "snapshot-request"
    public var surface: SurfaceID
    public var reason: SnapshotRequestReason
    /// Asks only the view of this attach stream (`attach-streams-v1`); nil asks every snapshot view of
    /// `surface` on the connection.
    public var stream: UInt16?

    public init(surface: SurfaceID, reason: SnapshotRequestReason, stream: UInt16? = nil) {
        self.surface = surface
        self.reason = reason
        self.stream = stream
    }
}
