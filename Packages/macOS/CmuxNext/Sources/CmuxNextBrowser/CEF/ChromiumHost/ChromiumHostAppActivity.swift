import AppKit
import CmuxNextCompat

/// What the Chromium host's scheduling follows (the `appActivity` frame): the
/// host holds a latency-critical activity, so macOS does not nap it, while
/// cmux is the active app or shows one of its pages, and ends it when cmux
/// hides (`browser_host_main.mm`, `SetAppActivity`).
nonisolated struct ChromiumHostAppActivity: Equatable, Sendable {
    /// cmux is the active app (and not hidden).
    var active: Bool
    /// A page of the host is on screen.
    var visible: Bool

    var frame: ChromiumHostFrame {
        ChromiumHostFrame(.appActivity, v: [active ? 1 : 0, visible ? 1 : 0])
    }
}

/// Reads ``ChromiumHostAppActivity`` again when cmux becomes active or
/// resigns, hides or unhides, or a window's occlusion changes, and reports
/// only a changed value.
@MainActor
final class ChromiumHostAppActivityMonitor {
    /// The value last read.
    private(set) var current: ChromiumHostAppActivity
    /// Called with each changed value.
    var onChange: (@MainActor (ChromiumHostAppActivity) -> Void)?
    private let read: @MainActor () -> ChromiumHostAppActivity
    private var observations: [MainActorObservation] = []

    static let changes: [Notification.Name] = [
        NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        NSApplication.didHideNotification, NSApplication.didUnhideNotification,
        NSWindow.didChangeOcclusionStateNotification,
    ]

    /// - Parameters:
    ///   - center: Where ``changes`` are posted (tests pass their own).
    ///   - read: The current value.
    init(center: NotificationCenter = .default, read: @escaping @MainActor () -> ChromiumHostAppActivity) {
        self.read = read
        current = read()
        observations = Self.changes.map { name in
            MainActorObservation(name, center: center) { [weak self] in self?.refresh() }
        }
    }

    /// Follows `app` and `page`: active while `app` is active and shown;
    /// visible while `page` is in a visible window and not hidden.
    convenience init(page: NSView, app: NSApplication = .shared, center: NotificationCenter = .default) {
        self.init(center: center) { [weak page, weak app] in
            guard let app, !app.isHidden else { return ChromiumHostAppActivity(active: false, visible: false) }
            let visible = page.map { !$0.isHiddenOrHasHiddenAncestor && $0.window?.occlusionState.contains(.visible) == true } ?? false
            return ChromiumHostAppActivity(active: app.isActive, visible: visible)
        }
    }

    /// Reads the value again; reports it when it changed. Also called when
    /// the page view moves (it has no notification of its own).
    func refresh() {
        let next = read()
        guard next != current else { return }
        current = next
        onChange?(next)
    }
}
