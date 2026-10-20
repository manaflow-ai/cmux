import AppKit
import Foundation

/// There is no public synchronous "is the screen locked" query on macOS. Two
/// de-facto sources exist: the `CGSSessionScreenIsLocked` key in
/// `CGSessionCopyCurrentDictionary()` and the `com.apple.screenIsLocked` /
/// `com.apple.screenIsUnlocked` distributed notifications. Either can be
/// absent in a given macOS version or session context, so the live provider
/// ORs both (`MacPresenceMonitor.consoleSessionActiveAndUnlocked`). If both
/// miss a lock, the failure mode is bounded: the 120 s hardware-idle rule
/// flips the Mac to away on its own shortly after the user leaves.
@MainActor
final class ScreenLockObserver {
    static let shared = ScreenLockObserver()

    private(set) var isLockedObserved = false

    /// Retained for the life of the process; the observer is a singleton
    /// whose lifetime is the app's.
    private var observerTokens: [any NSObjectProtocol] = []

    private init() {
        let center = DistributedNotificationCenter.default()
        observerTokens.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLockedObserved = true }
        })
        observerTokens.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLockedObserved = false }
        })
    }
}
