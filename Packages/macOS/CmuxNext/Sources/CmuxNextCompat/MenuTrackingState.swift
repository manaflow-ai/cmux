public import AppKit

/// The app's one observer of `NSMenu`'s begin and end of tracking (the menu bar, a context or a
/// pop-up menu): whether a menu tracks now, which one, and a fan-out of the ends to its subscribers.
///
/// The main run loop's `eventTracking` mode is not this signal: a window drag, a live resize, a
/// split divider, a scroller or a slider drag runs in it too, and no menu end follows them. Work
/// that waits for a menu to close (`ChromiumWarmup`) and `debug.hints` read this state. The
/// composition root makes one and passes it; tests make their own on their own center.
@MainActor
public final class MenuTrackingState {
    /// True between a menu's begin and end of tracking.
    public private(set) var isTracking = false
    /// The menu that tracks now; nil when none does.
    public private(set) var tracked: NSMenu?
    private var observations: [MainActorObservation] = []
    private var endHandlers: [EndHandler] = []

    private struct EndHandler {
        weak var token: EndToken?
        let call: @MainActor () -> Void
    }

    private final class EndToken {}

    /// - Parameter center: The center the menu notices come from (tests pass their own).
    public init(center: NotificationCenter = .default) {
        observations = [
            MainActorObservation(NSMenu.didBeginTrackingNotification, center: center, read: { $0.object as? NSMenu }) { [weak self] menu in
                self?.isTracking = true
                self?.tracked = menu
            },
            MainActorObservation(NSMenu.didEndTrackingNotification, center: center,
                                 read: { ($0.object as AnyObject?).map(ObjectIdentifier.init) }) { [weak self] menu in
                self?.ended(menu)
            },
        ]
    }

    /// Calls `ended` at each end of menu tracking, after this state reads no menu, until the
    /// returned token is released.
    public func observeEnd(_ ended: @escaping @MainActor () -> Void) -> AnyObject {
        let token = EndToken()
        endHandlers.removeAll { $0.token == nil }
        endHandlers.append(EndHandler(token: token, call: ended))
        return token
    }

    /// Ends the tracked menu's tracking (a script's dismiss or pick) and forgets it at once; its end
    /// notice follows.
    public func closeTracked() {
        tracked?.cancelTracking()
        tracked = nil
    }

    private func ended(_ menu: ObjectIdentifier?) {
        isTracking = false
        if tracked.map(ObjectIdentifier.init) == menu { tracked = nil }
        endHandlers.removeAll { $0.token == nil }
        for handler in endHandlers {
            handler.call()
        }
    }
}
