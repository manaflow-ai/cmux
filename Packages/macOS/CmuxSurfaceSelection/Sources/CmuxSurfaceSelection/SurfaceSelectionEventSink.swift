/// App-owned sink used by the reusable publisher to publish an opted-in event.
@MainActor
public protocol SurfaceSelectionEventSink: AnyObject {
    /// Whether a client currently requests the protected selection topic.
    func hasOptInSubscriber() -> Bool

    /// Publishes one immutable selection snapshot and reports acceptance.
    @discardableResult
    func publish(
        identity: SurfaceSelectionEventIdentity,
        snapshot: SurfaceSelectionEventSnapshot
    ) -> Bool
}
