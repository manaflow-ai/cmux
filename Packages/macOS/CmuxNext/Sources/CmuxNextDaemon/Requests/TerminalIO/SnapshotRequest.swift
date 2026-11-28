/// One READY + history on the caller's snapshot attach of `surface`
/// (`terminal-snapshot-v1`). Fire-and-forget from the view.
public struct SnapshotRequestRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "snapshot-request"
    public var surface: SurfaceID
    public var reason: SnapshotRequestReason

    public init(surface: SurfaceID, reason: SnapshotRequestReason) {
        self.surface = surface
        self.reason = reason
    }
}
