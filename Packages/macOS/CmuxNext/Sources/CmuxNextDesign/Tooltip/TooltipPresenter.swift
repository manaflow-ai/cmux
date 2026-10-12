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

    private let timer: DemandTimer
    private(set) lazy var panel = TooltipPanel()
    private weak var hovered: TooltipTracker?
    private var hiddenAt: ContinuousClock.Instant?
    private var monitor: Any?

    /// The text and shortcut on screen, nil while hidden (tests and debug).
    public private(set) var shown: (text: String, shortcut: String?)?

    init(clock: any Clock<Duration> = ContinuousClock()) {
        timer = DemandTimer(owner: "tooltip", clock: clock)
    }

    /// The pointer entered a view with a tooltip.
    func enter(_ tracker: TooltipTracker) {
        guard tracker !== hovered else { return }
        let warm = shown != nil || hiddenAt.map { $0.duration(to: .now) < Self.warm } ?? false
        hide()
        hovered = tracker
        watch()
        if warm {
            show()
        } else {
            timer.schedule(after: Self.delay) { @MainActor [weak self] in self?.show() }
        }
    }

    /// The pointer left the view.
    func exit(_ tracker: TooltipTracker) {
        guard tracker === hovered else { return }
        hide()
    }

    /// The hovered view's tooltip changed: show the new text, or hide when it has none.
    func changed(_ tracker: TooltipTracker) {
        guard tracker === hovered, shown != nil else { return }
        if tracker.text?.isEmpty == false { show() } else { hide() }
    }

    /// Puts the tooltip away; the next one waits the full delay.
    public func dismiss() {
        hide()
        hiddenAt = nil
    }

    /// Shows the pending tooltip now, as if the delay passed (tests).
    func fire() {
        timer.cancel()
        show()
    }

    private func show() {
        guard let tracker = hovered, let view = tracker.view, let window = view.window,
              let text = tracker.text, !text.isEmpty else { return }
        let style = view.performWithTheme { TooltipStyle.current() }
        panel.show(text: text, shortcut: tracker.shortcut, style: style, appearance: view.effectiveAppearance)
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor.insetBy(dx: -1000, dy: -1000)
        panel.setFrameOrigin(Self.origin(for: panel.frame.size, below: anchor, on: screen))
        panel.orderFrontRegardless()
        shown = (text, tracker.shortcut)
    }

    private func hide() {
        timer.cancel()
        if shown != nil {
            hiddenAt = .now
            panel.orderOut(nil)
        }
        shown = nil
        hovered = nil
        unwatch()
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
