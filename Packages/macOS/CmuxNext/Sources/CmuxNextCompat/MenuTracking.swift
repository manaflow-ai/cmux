public import AppKit

/// The menus AppKit tracks, as it posts `NSMenu.didBeginTrackingNotification` and
/// `didEndTrackingNotification`: delivered at once, in the poster's own call, on the main actor (a
/// press that opens a menu sees it before the press returns). The one seam for those two system
/// notices (plans/cmux-next/PATTERNS.md P2, P3): an owner keeps one while it follows menus and
/// subscribes; releasing it stops observing.
@MainActor
public final class MenuTracking {
    /// A menu began or ended tracking.
    public enum Change {
        case began(NSMenu)
        case ended(NSMenu)
    }

    private var subscribers: [(Change) -> Void] = []
    private var observations: [MainActorObservation] = []

    /// - Parameter center: Where the menus' notices are posted (tests pass their own).
    public init(center: NotificationCenter = .default) {
        observations = [
            MainActorObservation(NSMenu.didBeginTrackingNotification, center: center, atOnce: true, read: { $0.object as? NSMenu }) { [weak self] menu in
                if let menu { self?.send(.began(menu)) }
            },
            MainActorObservation(NSMenu.didEndTrackingNotification, center: center, atOnce: true, read: { $0.object as? NSMenu }) { [weak self] menu in
                if let menu { self?.send(.ended(menu)) }
            },
        ]
    }

    /// Calls `handler` with each change from now on, until this is released.
    public func subscribe(_ handler: @escaping (Change) -> Void) {
        subscribers.append(handler)
    }

    private func send(_ change: Change) {
        for subscriber in subscribers { subscriber(change) }
    }
}
