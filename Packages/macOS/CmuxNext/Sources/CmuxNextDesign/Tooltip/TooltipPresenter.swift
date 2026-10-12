public import AppKit
import CmuxNextWakeups

/// The app's one tooltip (Leo, 2026-10-12: no stock macOS bubble). A view sets `themedToolTip`
/// (`.themedHelp` in SwiftUI); hovering it shows this tooltip after `delay`, at once when the pointer
/// moves on from one just shown (along a rail or a toolbar), below the view and kept on screen. It
/// draws in the view's theme scope: the elevated surface, the primary ink, a hairline border, a
/// small radius and a shortcut hint in the secondary ink. Pages draw the same tooltip
/// (webviews/src/ui/titleTooltips.ts, `.ui-tooltip`). A click, a key, a scroll or the app going
/// inactive puts it away.
@MainActor
public final class TooltipPresenter {
    public static let shared = TooltipPresenter()
    /// Hover time before the first tooltip (the pages' `TOOLTIP_DELAY`).
    public static let delay: Duration = .milliseconds(500)
    /// How long after one hides the next shows without the delay (`TOOLTIP_WARM`).
    public static let warm: Duration = .milliseconds(400)
    /// Room kept between the tooltip and the screen's edges, and its gap from the view.
    static let edge: CGFloat = 6
    static let gap: CGFloat = 6

    /// How often a shown tooltip checks that its view is still under the pointer and on screen (a view
    /// removed, hidden or scrolled away sends no exit). Only while one is on screen.
    static let recheck: Duration = .milliseconds(500)

    private let timer: DemandTimer
    private let checker: DemandTimer
    private(set) lazy var panel = TooltipPanel()
    /// Trackers the pointer is inside (entered, not exited); the deepest one with text shows.
    private var inside: [TooltipTracker] = []
    private weak var current: TooltipTracker?
    private var hiddenAt: ContinuousClock.Instant?
    private var monitor: Any?

    /// The text and shortcut on screen, nil while hidden (tests and debug).
    public private(set) var shown: (text: String, shortcut: String?)?

    init(clock: any Clock<Duration> = ContinuousClock()) {
        timer = DemandTimer(owner: "tooltip", clock: clock)
        checker = DemandTimer(owner: "tooltip-check", clock: clock)
    }

    /// The pointer entered a tooltip's view or region.
    func enter(_ tracker: TooltipTracker) {
        if !inside.contains(where: { $0 === tracker }) { inside.append(tracker) }
        resolve()
    }

    /// The pointer left it.
    func exit(_ tracker: TooltipTracker) {
        inside.removeAll { $0 === tracker }
        resolve()
    }

    /// A tooltip's text changed: the shown one shows the new text, or hides when it has none.
    func changed(_ tracker: TooltipTracker) {
        guard tracker === current else { return }
        if tracker.text == nil {
            exit(tracker)
        } else if shown != nil {
            show()
        }
    }

    /// Puts the tooltip away; nothing shows again until the pointer enters another view.
    public func dismiss() {
        inside.removeAll()
        hide()
        hiddenAt = nil
    }

    /// Shows the pending tooltip now, as if the delay passed (tests).
    func fire() {
        timer.cancel()
        show()
    }

    /// Picks the deepest tooltip under the pointer and shows it: after the delay, or at once when one
    /// was just on screen (moving along a rail or a toolbar).
    private func resolve() {
        inside.removeAll { $0.view == nil || $0.text == nil }
        let target = inside.max { $0.depth < $1.depth }
        guard target !== current else { return }
        let warm = shown != nil || hiddenAt.map { $0.duration(to: .now) < Self.warm } ?? false
        hide()
        current = target
        guard target != nil else { return }
        watch()
        if warm {
            show()
        } else {
            timer.schedule(after: Self.delay) { @MainActor [weak self] in self?.show() }
        }
    }

    private func show() {
        guard let tracker = current, let view = tracker.view, let window = view.window,
              let text = tracker.text, let anchor = tracker.screenRect else { return }
        let style = view.performWithTheme { TooltipStyle.current() }
        panel.show(text: text, shortcut: tracker.shortcut, style: style, appearance: view.effectiveAppearance)
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? window.screen ?? NSScreen.main
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, below: anchor, on: screen?.visibleFrame ?? anchor.insetBy(dx: -1000, dy: -1000)))
        panel.orderFrontRegardless()
        shown = (text, tracker.shortcut)
        scheduleCheck()
    }

    private func hide() {
        timer.cancel()
        checker.cancel()
        if shown != nil {
            hiddenAt = .now
            panel.orderOut(nil)
        }
        shown = nil
        current = nil
        if inside.isEmpty { unwatch() }
    }

    /// While a tooltip shows: its view still in a visible window, not hidden, the app active and the
    /// pointer over it; else it goes, as if the pointer left.
    private func scheduleCheck() {
        checker.schedule(after: Self.recheck) { @MainActor [weak self] in
            guard let self, let tracker = current, shown != nil else { return }
            if Self.stillShows(tracker) { scheduleCheck() } else { exit(tracker) }
        }
    }

    static func stillShows(_ tracker: TooltipTracker) -> Bool {
        guard let view = tracker.view, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
              WindowPlacement.noActivate || NSApp.isActive, let anchor = tracker.screenRect else { return false }
        return anchor.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
    }

    /// Below the view and centered, above it when there is no room below, shifted to stay on screen
    /// (screen coordinates: y grows upward).
    static func origin(for size: NSSize, below anchor: NSRect, on screen: NSRect) -> NSPoint {
        let below = anchor.minY - gap - size.height
        let y = below >= screen.minY + edge ? below : min(anchor.maxY + gap, screen.maxY - edge - size.height)
        let centered = anchor.midX - size.width / 2
        let x = min(max(screen.minX + edge, centered), max(screen.minX + edge, screen.maxX - edge - size.width))
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    private func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel, .appKitDefined]
        ) { [weak self] event in
            if event.type != .appKitDefined || event.subtype == .applicationDeactivated { self?.dismiss() }
            return event
        }
    }

    private func unwatch() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
