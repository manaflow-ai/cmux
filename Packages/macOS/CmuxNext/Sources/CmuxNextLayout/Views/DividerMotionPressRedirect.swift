import AppKit
import CmuxNextDesign

/// Takes a press on a divider that a layout motion moved away from its catcher panel.
///
/// During a spring (a split, a close, a divider drag's release, a momentum strip scroll) the
/// catcher panels stay where the dividers rested (`DividerMouseCatchers`: no window server move
/// per frame); a panel whose divider moved lets the mouse through, and a divider's new place has
/// no panel until the motion lands. A press there came to the Chromium page under it, so a
/// re-grab during a release spring selected text or followed a link instead of resizing. While
/// such dividers exist, a local event monitor sends a press on one of them, and that press's drags
/// and release, to the parent window, where the divider view takes them as it takes a catcher's.
/// The monitor exists only while a motion moves dividers over a visible page, or a press it took
/// is held.
@MainActor
final class DividerMotionPressRedirect {
    /// The parent window; weak, so a press arriving after the window closed is left alone.
    private weak var window: NSWindow?
    /// Hit areas (window coordinates) of dividers away from their catcher panel; empty at rest.
    private(set) var areas: [LayoutMouseArea] = []
    /// Catcher panels show (a page window is visible and nothing blocks the window).
    private var isActive = false
    private var monitor: Any?
    /// The page window whose press went to the parent: its drags and release follow it there.
    private weak var pressWindow: NSWindow?
    /// Sends a page window's event to the parent window. A seam: tests record instead.
    var forward: @MainActor (NSEvent, NSWindow) -> Void = { forwardDividerMouseEvent($0, to: $1) }

    init(window: NSWindow) {
        self.window = window
    }

    /// Whether the event monitor is installed (tests).
    var isMonitoring: Bool { monitor != nil }
    /// Whether a press this redirect took is held.
    var isPressing: Bool { pressWindow != nil }

    /// Called on every overlay sync of a motion frame: a store, plus a monitor change only when
    /// a motion starts or lands. No window server work.
    func update(areas: [LayoutMouseArea]) {
        self.areas = areas
        updateMonitor()
    }

    /// The catchers showed or hid (`DividerMouseCatchers.update`).
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        updateMonitor()
    }

    func teardown() {
        areas = []
        isActive = false
        pressWindow = nil
        updateMonitor()
    }

    private func updateMonitor() {
        let wanted = (isActive && !areas.isEmpty) || pressWindow != nil
        if wanted, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                                                  .rightMouseDown, .rightMouseUp]) { [weak self] event in
                self?.handle(event) ?? event
            }
        } else if !wanted, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// The monitor's handler: nil when the event went to the parent window.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let window else { return event }
        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            guard pressWindow == nil, isActive, let source = event.window, source !== window, source.parent === window,
                  source.isVisible, WindowOverlayHost.isPageWindow(source) else { return event }
            let point = window.convertPoint(fromScreen: source.convertPoint(toScreen: event.locationInWindow))
            guard areas.contains(where: { $0.rect.contains(point) }) else { return event }
            pressWindow = source
            updateMonitor()
            forward(event, window)
            return nil
        case .leftMouseDragged, .leftMouseUp, .rightMouseUp:
            guard let pressWindow, event.window === pressWindow else { return event }
            forward(event, window)
            if event.type != .leftMouseDragged {
                self.pressWindow = nil
                updateMonitor()
            }
            return nil
        default:
            return event
        }
    }
}
