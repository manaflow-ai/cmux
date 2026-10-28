public import AppKit
import CmuxNextWakeups
public import CmuxNextDesignTokens

/// The app's one tooltip (Leo, 2026-10-12: no stock macOS bubble). A view sets `themedToolTip`
/// (`.themedHelp` in SwiftUI); hovering it shows this tooltip below the view, kept on screen, with
/// AppKit's hover intent (Leo, 2026-10-14; `HoverIntent`): the first waits `tooltipDelay`, a
/// neighbor's then shows at once while the group is warm, and a control whose own label already
/// names it shows none. The first of a group fades in and rises 2 pt; a warm neighbor's is
/// there at once; each fades out quicker than it came. It draws in the view's theme scope on the
/// shared overlay glass (`Glass.makeOverlayPanel`, the hover cards' too; a small tight shadow)
/// under the legibility tint (`TooltipSurface.tint`), with a shortcut hint in the secondary ink. Pages draw the same tooltip
/// (webviews/src/ui/titleTooltips.ts, `.ui-tooltip`). A click, a key, a scroll or the app going
/// inactive puts it away.
@MainActor
public final class TooltipPresenter {
    public static let shared = TooltipPresenter()
    /// Room kept between the tooltip and the screen's edges, and its gap from the view.
    static let edge: CGFloat = 6
    static let gap: CGFloat = 6

    /// How often a shown tooltip checks that its view is still under the pointer and on screen (a view
    /// removed, hidden or scrolled away sends no exit). Only while one is on screen.
    static let recheck: Duration = .milliseconds(500)
    /// How long the scrolling stays still before the row under the pointer shows its tooltip.
    static let scrollQuiet: Duration = .milliseconds(150)

    private let checker: DemandTimer
    private let quiet: DemandTimer
    /// The hover intent's one timer: the initial delay, then the warm group's cool-down.
    private let intentTimer: DemandTimer
    private var intent = HoverIntent<ObjectIdentifier>(delay: HoverIntentTiming.standard.tooltipDelay,
                                                       warmFor: HoverIntentTiming.standard.tooltipWarm)
    /// The timing to use instead of the tunables' (tests).
    var timing: HoverIntentTiming?
    /// The tooltip the pointer rests on, shown or waiting for its delay.
    private weak var candidate: TooltipTracker?
    /// A scroll is under way: rows pass under the pointer, and none shows its tooltip.
    private var scrolling = false
    private(set) lazy var panel = TooltipPanel()
    /// Trackers the pointer is inside (entered, not exited); the deepest one with text shows.
    private var inside: [TooltipTracker] = []
    private weak var current: TooltipTracker?
    private var monitor: Any?

    /// The text and shortcut on screen, nil while hidden (tests and debug).
    public private(set) var shown: (text: String, shortcut: String?)?

    init(clock: any Clock<Duration> = ContinuousClock()) {
        checker = DemandTimer(owner: "tooltip-check", clock: clock)
        quiet = DemandTimer(owner: "tooltip-scroll", clock: clock)
        intentTimer = DemandTimer(owner: "tooltip-intent", clock: clock)
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

    /// Puts the tooltip away; nothing shows again until the pointer enters another view, and the
    /// next one waits the full delay (a click or a key ends the warm group, as in AppKit).
    public func dismiss() {
        inside.removeAll()
        candidate = nil
        run(intent.dismiss())
        hide(immediately: true)
    }

    /// A scroll-wheel event: the tooltip goes, and the rows that pass under the pointer show none
    /// (shown at once, each flashed by). Once the scrolling stops, the row under the pointer shows its.
    func scrolled() {
        if !scrolling {
            dismiss()
            scrolling = true
            watch()
        }
        quiet.schedule(after: Self.scrollQuiet) { @MainActor [weak self] in
            guard let self else { return }
            scrolling = false
            resolve()
            if inside.isEmpty, !scrolling { unwatch() }
        }
    }

    /// Picks the deepest tooltip under the pointer and hands it to the hover intent, which shows it
    /// after the delay or at once while warm.
    private func resolve() {
        inside.removeAll { $0.view == nil || $0.text == nil }
        guard !scrolling else { return }
        // The deepest tooltip under the pointer; when its control's label already names it, none
        // (not an ancestor's instead, as pages do). AppKit can report a view's visible rect past
        // its bounds, so its area is entered far from the view (the sidebar's bottom item, over the
        // whole sidebar): only those whose view is under the pointer compete, when it is known.
        let target = Self.underPointer(inside).max { $0.depth < $1.depth }.flatMap { $0.repeatsVisibleLabel ? nil : $0 }
        candidate = target
        if target != nil { watch() }
        let timing = self.timing ?? .current
        intent.delay = timing.tooltipDelay
        intent.warmFor = timing.tooltipWarm
        // A tooltip of a warm group is there at once; only the first of a group fades in.
        let warm = intent.isWarm
        run(intent.hover(target.map(ObjectIdentifier.init)), fade: !warm)
        if target == nil, inside.isEmpty, shown == nil, !intent.isWarm { unwatch() }
    }

    private func run(_ effects: [HoverIntent<ObjectIdentifier>.Effect], fade: Bool = true) {
        for effect in effects {
            switch effect {
            case .schedule(let token, let delay):
                intentTimer.schedule(after: delay) { @MainActor [weak self] in self?.deadline(token) }
            case .cancelTimer:
                intentTimer.cancel()
            case .show(let id):
                hide()
                guard let tracker = candidate, ObjectIdentifier(tracker) == id else {
                    _ = intent.dismiss()
                    continue
                }
                current = tracker
                watch()
                show(fade: fade)
                // Its view left its window or lost its text while it waited: nothing shows, so the
                // intent must not think one does (the next would skip its delay).
                if shown == nil { _ = intent.dismiss() }
            case .hide:
                hide()
            }
        }
    }

    private func deadline(_ token: Int) {
        run(intent.deadline(token))
        if inside.isEmpty, shown == nil, !scrolling, !intent.isWarm { unwatch() }
    }

    /// Shows `current`: fading in when `fade` (the first of a warm group), else at once.
    private func show(fade: Bool = false) {
        guard let tracker = current, let view = tracker.view, let window = view.window,
              let text = tracker.text, let anchor = tracker.screenRect else { return }
        let center = NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? window.screen ?? NSScreen.main
        panel.show(text: text, shortcut: tracker.shortcut, scope: view.themeScope.fullStrength,
                   appearance: view.effectiveAppearance)
        // The surface sits `margin` inside the window (room for its shadow): place the surface.
        let origin = Self.origin(for: panel.surfaceSize, below: anchor, on: screen?.visibleFrame ?? anchor.insetBy(dx: -1000, dy: -1000))
        panel.setFrameOrigin(NSPoint(x: origin.x - TooltipPanel.margin, y: origin.y - TooltipPanel.margin))
        panel.present(fade: fade)
        shown = (text, tracker.shortcut)
        scheduleCheck()
    }

    /// Hides what shows: fading out, or `immediately` (a click, a key, a scroll, the app going inactive).
    private func hide(immediately: Bool = false) {
        checker.cancel()
        if immediately {
            if panel.isVisible { panel.hideNow() }
        } else if shown != nil {
            panel.fadeOut()
        }
        shown = nil
        current = nil
        if inside.isEmpty, !scrolling, candidate == nil, !intent.isWarm { unwatch() }
    }

    /// While a tooltip shows: its view still in a visible window, not hidden, the app active and the
    /// pointer over it; else it goes, as if the pointer left.
    private func scheduleCheck() {
        checker.schedule(after: Self.recheck) { @MainActor [weak self] in
            guard let self, let tracker = current, shown != nil else { return }
            if Self.stillShows(tracker) { scheduleCheck() } else { exit(tracker) }
        }
    }

    /// The trackers whose view (or region) is under the pointer, or all of them when none is (the
    /// pointer unknown, or a view that moved since its area was entered).
    static func underPointer(_ trackers: [TooltipTracker]) -> [TooltipTracker] {
        let under = trackers.filter { tracker in
            guard let window = tracker.view?.window, let anchor = tracker.screenRect,
                  let pointer = PointerHover.pointer(in: window) else { return false }
            return anchor.insetBy(dx: -1, dy: -1).contains(window.convertPoint(toScreen: pointer))
        }
        return under.isEmpty ? trackers : under
    }

    static func stillShows(_ tracker: TooltipTracker) -> Bool {
        guard let view = tracker.view, let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
              WindowPlacement.noActivate || NSApp.isActive, let anchor = tracker.screenRect,
              let pointer = PointerHover.pointer(in: window) else { return false }
        // `PointerHover`: the real pointer, or DEBUG's synthesized one (a recording on a headless host).
        return anchor.insetBy(dx: -1, dy: -1).contains(window.convertPoint(toScreen: pointer))
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
            if event.type == .scrollWheel {
                self?.scrolled()
            } else if event.type != .appKitDefined || event.subtype == .applicationDeactivated {
                self?.dismiss()
            }
            return event
        }
    }

    private func unwatch() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
