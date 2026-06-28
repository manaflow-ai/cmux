import AppKit
import Foundation

/// Tracks the macOS screensaver's running state via the screensaver
/// daemon's Darwin distributed notifications, replacing the previous
/// approach of enumerating running applications to find
/// `com.apple.ScreenSaver.Engine`.
///
/// ## Why this exists
///
/// `NSWorkspace.shared.runningApplications` triggers the macOS
/// **App Management** privacy prompt
/// ("X would like to access data from other apps"). For cmux DEV builds
/// the App Management permission is keyed to bundle ID, and
/// `scripts/reload.sh --tag <name>` derives a unique bundle ID per tag
/// (line 519: `BUNDLE_ID="com.cmuxterm.app.debug.${TAG_ID}"`). That meant
/// every fresh tagged build re-prompted the user once the first
/// phone-forwarding notification reached the screensaver signal.
///
/// The fix subscribes to the screensaver daemon's Darwin distributed
/// notifications (`com.apple.screensaver.didstart` /
/// `com.apple.screensaver.didstop`) via `NSDistributedNotificationCenter`.
/// Distributed notifications are passive broadcasts — they never
/// enumerate apps and never trigger App Management TCC.
///
/// ## Default state and edge case
///
/// `isRunning` is initialized to `false` (screensaver not running). If
/// the screensaver was already running when cmux launched, we won't
/// detect it until the user wakes the screen and a `didstop`
/// notification fires. For the phone-forwarding "only when away"
/// heuristic this means one push may leak to the phone before we
/// re-detect — a deliberate trade-off for not enumerating apps at
/// launch.
@MainActor
final class ScreensaverStateTracker {
    /// Single source of truth, owned by the main actor (subscribing to
    /// distributed notifications is a main-actor operation).
    static let shared = ScreensaverStateTracker()

    /// Last observed screensaver running state. `true` after a
    /// `com.apple.screensaver.didstart` notification, `false` after a
    /// `com.apple.screensaver.didstop` notification, `false` before
    /// either fires.
    private(set) var isRunning: Bool = false

    /// Strong refs to the observer tokens — `addObserver` returns
    /// `NSObjectProtocol` tokens that must outlive the closure
    /// subscriptions.
    private var observers: [NSObjectProtocol] = []

    private init() {
        // The screensaver daemon posts these Darwin notifications via
        // NSDistributedNotificationCenter. Subscribing is passive — no
        // app enumeration, no TCC prompt. Names are stable across all
        // macOS versions that ship a screensaver daemon.
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isRunning = true
        })
        observers.append(center.addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isRunning = false
        })
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        for observer in observers {
            center.removeObserver(observer)
        }
    }
}
