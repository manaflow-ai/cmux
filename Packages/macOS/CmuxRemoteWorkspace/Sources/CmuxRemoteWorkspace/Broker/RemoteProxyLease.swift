internal import Foundation

/// A reference-counted subscription to a shared proxy tunnel handed out by
/// ``RemoteProxyBroker/acquire(configuration:remotePath:onUpdate:)``.
///
/// Releasing (explicitly or via `deinit`) unsubscribes; when the last lease
/// for a transport is released the broker tears the tunnel down.
///
/// Isolation design: a lease is owned by exactly one subscriber and released
/// from that subscriber's own serial context (the session controller queue or
/// `deinit` on last release), matching the legacy contract; `isReleased` is
/// that single owner's guard, not a cross-thread latch. The broker side of
/// `release` hops onto the broker queue internally.
public final class RemoteProxyLease {
    private let key: String
    private let subscriberID: UUID
    private weak var broker: RemoteProxyBroker?
    private var isReleased = false

    internal init(key: String, subscriberID: UUID, broker: RemoteProxyBroker) {
        self.key = key
        self.subscriberID = subscriberID
        self.broker = broker
    }

    /// Idempotently unsubscribes from the shared tunnel.
    public func release() {
        guard !isReleased else { return }
        isReleased = true
        broker?.release(key: key, subscriberID: subscriberID)
    }

    deinit {
        release()
    }
}
