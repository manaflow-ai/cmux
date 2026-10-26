import AppKit
import CmuxNextCompat

/// Whether an `NSMenu` tracks now (the menu bar, a context or a pop-up menu), from the menu's own
/// begin and end tracking notifications, and the end of that tracking.
///
/// The main run loop's `eventTracking` mode is not this signal: a window drag, a live resize, a
/// split divider, a scroller or a slider drag runs in it too, and no menu end follows them. Work
/// that waits for a menu to close (`ChromiumWarmup`) reads this state instead.
@MainActor
final class MenuTrackingState {
    /// True between a menu's begin and end of tracking.
    private(set) var isTracking = false
    private let center: NotificationCenter
    private var observations: [MainActorObservation] = []

    /// - Parameter center: The center the menu notifications come from (tests pass their own).
    init(center: NotificationCenter = .default) {
        self.center = center
        observations = [
            MainActorObservation(NSMenu.didBeginTrackingNotification, center: center) { [weak self] in self?.isTracking = true },
            MainActorObservation(NSMenu.didEndTrackingNotification, center: center) { [weak self] in self?.isTracking = false },
        ]
    }

    /// Calls `ended` at each end of menu tracking until the returned token is released.
    func observeEnd(_ ended: @escaping @MainActor () -> Void) -> AnyObject {
        MainActorObservation(NSMenu.didEndTrackingNotification, center: center, ended)
    }
}
