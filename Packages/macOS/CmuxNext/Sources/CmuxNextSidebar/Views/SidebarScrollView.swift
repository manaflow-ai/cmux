import AppKit

/// The sidebar list's scroll view. A two-finger horizontal trackpad swipe
/// over it switches profiles instead of scrolling; vertical scrolling
/// is unchanged. One switch per gesture (`ProfileSwipeTracker`). A sideways
/// mouse wheel (tilt, or Shift) pages the spaces too, one per roll
/// (`SpaceWheelPager`); up or down always scrolls the list.
///
/// The list takes AppKit's responsive scrolling: a vertical trackpad gesture is handed to AppKit
/// on its first event, which moves the clip off the main thread for the rest of the gesture, so
/// a busy main thread no longer stalls the scroll (Leo, ask-757eeb7f80: "scrolling thru sidebar
/// sessions in claude doesn't lag / in cmux-next it does"). Overriding `scrollWheel(with:)` alone
/// opted the list out, and every scroll frame waited on the main thread. A gesture
/// is held here, event by event, until it shows its direction (unless its first event already
/// does): sideways pages the spaces, otherwise AppKit takes it from there.
final class SidebarScrollView: NSScrollView {
    /// Called with -1 (previous) or +1 (next) once per qualifying swipe.
    var onHorizontalSwipe: ((Int) -> Void)?
    /// A horizontal gesture 1:1 (R99): its phase, finger dx and time. When
    /// set, it replaces the one-step swipe.
    var onHorizontalScroll: ((ProfileSwipeTracker.Phase, CGFloat, TimeInterval) -> Void)?
    /// A mouse wheel notch paged the spaces: -1 (previous) or +1 (next).
    var onWheelPage: ((Int) -> Void)?
    private var tracker = ProfileSwipeTracker()
    private var wheel = SpaceWheelPager()
    private var paging = false
    /// A trackpad gesture whose direction is not known yet: no event of it goes to AppKit, which
    /// would track the rest of the gesture itself and never pass on a sideways swipe.
    private var deciding = false

    /// AppKit asks this because `scrollWheel(with:)` is overridden: the override sees the first
    /// event of a gesture AppKit tracks, and that is all it needs (the type comment).
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, let phase = Self.phase(of: event) else {
            if let onWheelPage, !event.hasPreciseScrollingDeltas {
                switch wheel.feed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, time: event.timestamp, pagesVertically: false) {
                case .pass: break
                case .hold: return
                case .page(let step): return onWheelPage(step)
                }
            }
            super.scrollWheel(with: event)
            return
        }
        let step = tracker.feed(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), phase: phase)
        switch phase {
        case .began: deciding = !tracker.isVertical
        case .changed: if tracker.isVertical { deciding = false }
        case .ended, .momentum: deciding = false
        }
        if let onHorizontalScroll {
            if phase == .ended || phase == .momentum {
                if paging, phase == .ended { onHorizontalScroll(.ended, 0, event.timestamp) }
                paging = false
            } else if tracker.isHorizontal {
                onHorizontalScroll(paging ? .changed : .began, event.scrollingDeltaX, event.timestamp)
                paging = true
            }
        } else if let step {
            onHorizontalSwipe?(step)
        }
        // A horizontal gesture never scrolls the list; the list cannot
        // scroll horizontally anyway, and elastic bounce would jitter.
        if !tracker.isHorizontal, !deciding { super.scrollWheel(with: event) }
    }

    private static func phase(of event: NSEvent) -> ProfileSwipeTracker.Phase? {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.changed) { return .changed }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
        return nil
    }
}
