import AppKit

/// The sidebar list's scroll view. A two-finger horizontal trackpad swipe
/// over it switches profiles instead of scrolling; vertical scrolling
/// is unchanged. One switch per gesture (`ProfileSwipeTracker`). A mouse
/// wheel pages the spaces too (`SpaceWheelPager`): always sideways, and
/// up or down while every row fits.
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

    /// Every row fits: a vertical wheel has nothing to scroll, so it pages.
    var rowsFit: Bool {
        guard let documentView else { return true }
        return documentView.frame.height <= contentView.bounds.height + 0.5
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, let phase = Self.phase(of: event) else {
            if let onWheelPage, !event.hasPreciseScrollingDeltas {
                switch wheel.feed(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, time: event.timestamp, pagesVertically: rowsFit) {
                case .pass: break
                case .hold: return
                case .page(let step): return onWheelPage(step)
                }
            }
            super.scrollWheel(with: event)
            return
        }
        let step = tracker.feed(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), phase: phase)
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
        if !tracker.isHorizontal { super.scrollWheel(with: event) }
    }

    private static func phase(of event: NSEvent) -> ProfileSwipeTracker.Phase? {
        if !event.momentumPhase.isEmpty { return .momentum }
        if event.phase.contains(.began) { return .began }
        if event.phase.contains(.changed) { return .changed }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { return .ended }
        return nil
    }
}
