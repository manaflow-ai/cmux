import Foundation

/// A subscription to ``WindowEvents`` or ``AppEvents``. Releasing it (or ``cancel()``) ends it, and
/// the last subscription to a name removes that name's NotificationCenter observer.
@MainActor public final class EventSubscription {
    /// The subscriber's name for diagnostics.
    public let owner: String
    private weak var fanOut: NotificationFanOut?
    private let name: Notification.Name
    private let id: UInt64

    init(owner: String, fanOut: NotificationFanOut?, name: Notification.Name, id: UInt64) {
        self.owner = owner
        self.fanOut = fanOut
        self.name = name
        self.id = id
    }

    /// Ends the subscription now: no later call, a pending missed call included. Idempotent.
    public func cancel() {
        fanOut?.remove(name, id: id)
        fanOut = nil
    }

    deinit {
        guard let fanOut else { return }
        let name = self.name, id = self.id
        MainDelivery().run { fanOut.remove(name, id: id) }
    }
}
