import AppKit
import CmuxNextWakeups

/// Follows the strip's window becoming and leaving main: only the main
/// window's selected tab is filled (dogfood 2026-10-08, 08). Main, not key,
/// so a dialog or palette panel taking the keyboard leaves the strip as it is.
/// It subscribes to the window's one fan-out of each notice (``WindowEvents``), not to
/// NotificationCenter per strip, as Chromium's NSWindow delegate tells each view of its
/// window (components/remote_cocoa/app_shim/views_nswindow_delegate.mm). No node: the
/// strip follows only while it shows (`syncShown`).
@MainActor
final class WindowMainObserver {
    private(set) var isMain = true
    private var onChange: (Bool) -> Void = { _ in }
    private var subscriptions: [EventSubscription] = []

    /// Starts following `window` (nil stops) and reports its current status.
    func observe(_ window: NSWindow?, onChange: @escaping (Bool) -> Void) {
        for subscription in subscriptions { subscription.cancel() }
        subscriptions = []
        self.onChange = onChange
        guard let window else { return }
        changed(isMain: window.isMainWindow)
        let events = WindowEvents.of(window)
        subscriptions = [
            events.subscribe(NSWindow.didBecomeMainNotification, owner: "TabStrip.windowMain") { [weak self] in self?.changed(isMain: true) },
            events.subscribe(NSWindow.didResignMainNotification, owner: "TabStrip.windowMain") { [weak self] in self?.changed(isMain: false) },
        ]
    }

    func changed(isMain: Bool) {
        self.isMain = isMain
        onChange(isMain)
    }
}
