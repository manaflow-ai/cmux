import AppKit
import CmuxNextCompat

/// The moments a status indicator checks itself again, heard once per app and handed only to the
/// windows they concern (P3).
///
/// A window becoming main and a window's occlusion change go to that window's
/// ``WindowIndicatorResync`` alone, found by the window's identity (O(1) per notice). An app-wide
/// moment (activation, unhide, wake, screens wake, a session switch back) goes to each window that
/// holds an indicator, which resyncs when it is on screen and otherwise owes one until it shows.
/// Each window used to register its own observer of every moment and of its own occlusion: an
/// app-wide moment woke one observer per window.
///
/// It observes only while some window holds an indicator, so an app without one costs nothing. The
/// app owns one (``StatusIndicatorAppearance``'s); tests make their own on their own centers and
/// hand it to their windows through ``WindowKeyEnvironment/resyncMoments``.
@MainActor
final class IndicatorResyncMoments {
    /// A window's indicator set, held weakly: it lives as long as its window's ``WindowKeyFamily``.
    private struct Filed {
        weak var indicators: WindowIndicatorResync?
    }

    private let app: NotificationCenter
    private let workspace: NotificationCenter
    /// The windows that hold an indicator now, by window identity.
    private var windows: [ObjectIdentifier: Filed] = [:]
    private var observers: [MainActorObservation] = []

    /// - Parameters:
    ///   - app: Where the app and window notices arrive (tests post to their own).
    ///   - workspace: Where the Mac's wake and session notices arrive.
    init(app: NotificationCenter = .default, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.app = app
        self.workspace = workspace
    }

    /// Whether `indicators` is filed: it hears its window's moments.
    func isFiled(_ indicators: WindowIndicatorResync) -> Bool {
        windows[indicators.windowID]?.indicators === indicators
    }

    /// Files `indicators` under its window (its first indicator entered).
    func file(_ indicators: WindowIndicatorResync) {
        windows[indicators.windowID] = Filed(indicators: indicators)
        if observers.isEmpty { startObserving() }
    }

    /// Takes `indicators` out (its last indicator left); the last one out stops the observers.
    func unfile(_ indicators: WindowIndicatorResync) {
        guard isFiled(indicators) else { return }
        drop(indicators.windowID)
    }

    private func startObserving() {
        let notices: [(NotificationCenter, Notification.Name)] = [
            (app, NSWindow.didBecomeMainNotification), (app, NSWindow.didChangeOcclusionStateNotification),
            (app, NSApplication.didBecomeActiveNotification), (app, NSApplication.didUnhideNotification),
            (workspace, NSWorkspace.didWakeNotification), (workspace, NSWorkspace.screensDidWakeNotification),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        observers = notices.map { center, name in
            MainActorObservation(name, center: center, read: { $0.object.map { ObjectIdentifier($0 as AnyObject) } }) { [weak self] sender in
                self?.arrived(name, from: sender)
            }
        }
    }

    private func arrived(_ name: Notification.Name, from sender: ObjectIdentifier?) {
        switch name {
        case NSWindow.didBecomeMainNotification:
            if let sender { indicators(of: sender)?.resync() }
        case NSWindow.didChangeOcclusionStateNotification:
            if let sender { indicators(of: sender)?.occlusionChanged() }
        default:
            // The keys are copied first: a resync can make a window's last indicator leave.
            for window in Array(windows.keys) { indicators(of: window)?.appCameBack() }
        }
    }

    /// The indicator set of `window` (nil: it holds no indicator). The entry of a window torn down
    /// with its indicators in it (no leave posted) is dropped here, so it costs no later moment.
    private func indicators(of window: ObjectIdentifier) -> WindowIndicatorResync? {
        guard let filed = windows[window] else { return nil }
        if let indicators = filed.indicators, indicators.hasWindow { return indicators }
        drop(window)
        return nil
    }

    private func drop(_ window: ObjectIdentifier) {
        windows[window] = nil
        if windows.isEmpty { observers.removeAll() }
    }
}
