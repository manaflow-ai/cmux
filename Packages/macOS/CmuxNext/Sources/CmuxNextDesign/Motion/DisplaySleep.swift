import AppKit

/// Whether a screen's display is asleep, for ``Motion/canAnimate(in:)``.
///
/// A sleeping display draws no frame, so an AppKit animation in a window on
/// it never advances: its view stays where the animation left it (an
/// inserted sidebar row at alpha 0) until something else sets it. A change
/// there applies at once instead, and one already running when the display
/// goes to sleep ends at once if it opted in (``MotionInFlight``).
///
/// Core Graphics' state of the window's display decides. The workspace's
/// sleep and wake notifications only trigger the end of running animations,
/// so a sleep posted with no matching wake cannot leave later changes snapping.
@MainActor
final class DisplaySleep {
    static let shared = DisplaySleep()

    /// Tests pin the answer for every display; nil asks Core Graphics.
    static var asleepOverride: Bool?

    private var observers: [any NSObjectProtocol] = []

    private init() {
        // Sleep ends what is running; wake ends what froze in the gap. Neither sets a state.
        let center = NSWorkspace.shared.notificationCenter
        observers = [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // main-proof: the observer runs on the main queue (queue: .main)
                MainActor.assumeIsolated { MotionInFlight.finish() }
            }
        }
    }

    /// Whether `screen`'s display draws no frames now.
    func isAsleep(_ screen: NSScreen) -> Bool {
        if let override = Self.asleepOverride { return override }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsAsleep(CGDirectDisplayID(number.uint32Value)) != 0
    }

}
