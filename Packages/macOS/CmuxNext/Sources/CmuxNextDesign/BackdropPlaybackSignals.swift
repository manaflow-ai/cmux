import AppKit
import CmuxNextCompat
import CmuxNextDesignTokens

/// The events a moving backdrop (``BackdropVideoView``, ``BackdropLiveView``) runs or rests on, watched
/// for one view's window: its occlusion, miniaturize, key and main state and close; the app hiding;
/// the thermal state; Reduce Motion and the animation speed; the screens sleeping and the session
/// switching; Low Power Mode. It keeps whether the screens sleep and whether the session is
/// inactive (no API reads those), and tells its owner which kind of event came; the owner reads
/// everything else itself when it decides.
///
/// One per view, watching only while the view is in a window: the view calls ``watch(_:)`` with
/// its window, and with nil when it leaves it, so a view out of a window observes nothing.
final class BackdropPlaybackSignals {
    /// What happened, as the owner acts on it.
    enum Signal {
        /// The window is closing: let go of what it holds now, not when the view goes.
        case closing
        /// The window came to the front: what covered it may be gone, so coverage starts over.
        case raised
        /// Anything else that may change whether it runs.
        case changed
    }

    /// The screens are asleep (between `screensDidSleep` and `screensDidWake`).
    private(set) var screensAsleep = false
    /// Another user's session is in front (between `sessionDidResignActive` and `sessionDidBecomeActive`).
    private(set) var sessionInactive = false
    private let changed: @MainActor (Signal) -> Void
    private var observers: [MainActorObservation] = []
    /// The app's Low Power Mode (``LowPowerMode/system``, the `debug.low_power_mode` override included).
    private var powerObservation: LowPowerModeObservation?

    /// Signals go to `changed`, on the main thread.
    init(_ changed: @escaping @MainActor (Signal) -> Void) {
        self.changed = changed
    }

    /// Watches `window`'s events and the app's; nil stops watching.
    func watch(_ window: NSWindow?) {
        stop()
        guard let window else { return }
        powerObservation = LowPowerMode.system.observe { [weak self] _ in self?.changed(.changed) }
        let app = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
        var names: [(NotificationCenter, Notification.Name, AnyObject?)] = [
            (app, NSWindow.didChangeOcclusionStateNotification, window), (app, NSWindow.didMiniaturizeNotification, window),
            (app, NSWindow.didDeminiaturizeNotification, window), (app, NSWindow.didBecomeMainNotification, window),
            (app, NSWindow.didBecomeKeyNotification, window), (app, NSApplication.didHideNotification, nil),
            (app, NSApplication.didUnhideNotification, nil),
            (app, ProcessInfo.thermalStateDidChangeNotification, nil), (app, Motion.reduceMotionDidChange, nil),
            (app, Motion.speedDidChange, nil),
            (workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, nil),
        ]
        names.append((app, NSWindow.willCloseNotification, window))
        names += [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                  NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification].map { (workspace, $0, nil) }
        observers = names.map { center, name, object in
            MainActorObservation(name, object: object, center: center) { [weak self] in self?.note(name) }
        }
    }

    private func stop() {
        observers = []
        powerObservation = nil
    }

    private func note(_ name: Notification.Name) {
        switch name {
        case NSWindow.willCloseNotification: return changed(.closing)
        case NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification: return changed(.raised)
        case NSWorkspace.screensDidSleepNotification: screensAsleep = true
        case NSWorkspace.screensDidWakeNotification: screensAsleep = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionInactive = false
        default: break
        }
        changed(.changed)
    }
}
