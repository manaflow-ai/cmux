import AppKit

/// Whether a screen's display is asleep, for ``Motion/canAnimate(in:)``.
///
/// A sleeping display draws no frame, so an AppKit animation in a window on
/// it never advances: its view stays at the start value (an inserted sidebar
/// row at alpha 0) until something else sets it. A change there applies at
/// once instead.
///
/// Two sources, either one enough: the workspace's sleep and wake
/// notifications (posted on each transition), and Core Graphics' state of the
/// window's display (a launch while the display already sleeps gets no
/// notification).
@MainActor
final class DisplaySleep {
    static let shared = DisplaySleep()

    private var notifiedAsleep = false
    private var observers: [any NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        observers = [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)].map { name, asleep in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // main-proof: the observer runs on the main queue (queue: .main)
                MainActor.assumeIsolated { self?.notifiedAsleep = asleep }
            }
        }
    }

    /// Whether `screen`'s display draws no frames now.
    func isAsleep(_ screen: NSScreen) -> Bool {
        if notifiedAsleep { return true }
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsAsleep(CGDirectDisplayID(number.uint32Value)) != 0
    }
}
