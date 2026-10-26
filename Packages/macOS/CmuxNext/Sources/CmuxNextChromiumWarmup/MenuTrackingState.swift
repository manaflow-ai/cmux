public import AppKit
public import CmuxNextWakeups

/// Whether an `NSMenu` tracks now (the menu bar, a context or a pop-up menu), from the menu's own
/// begin and end tracking notices on the app's ``AppEvents`` fan-out, and the end of that tracking.
///
/// The main run loop's `eventTracking` mode is not this signal: a window drag, a live resize, a
/// split divider, a scroller or a slider drag runs in it too, and no menu end follows them.
/// ``ChromiumWarmup`` steps that wait for a menu to close read this state instead.
@MainActor
public final class MenuTrackingState {
    /// True between a menu's begin and end of tracking.
    public private(set) var isTracking = false
    private let events: AppEvents
    private var subscriptions: [EventSubscription] = []

    /// - Parameter events: The app's one fan-out of app-wide notices (tests make their own).
    public init(events: AppEvents) {
        self.events = events
        subscriptions = [
            events.subscribe(NSMenu.didBeginTrackingNotification, owner: "MenuTrackingState") { [weak self] in self?.isTracking = true },
            events.subscribe(NSMenu.didEndTrackingNotification, owner: "MenuTrackingState") { [weak self] in self?.isTracking = false },
        ]
    }

    /// Calls `ended` at each end of menu tracking until the returned token is released.
    public func observeEnd(_ ended: @escaping @MainActor () -> Void) -> AnyObject {
        events.subscribe(NSMenu.didEndTrackingNotification, owner: "ChromiumWarmup.menuEnd", ended)
    }
}
