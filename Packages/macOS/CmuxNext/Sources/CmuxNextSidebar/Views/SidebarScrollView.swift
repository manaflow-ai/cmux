import AppKit

/// The sidebar list's scroll view. A two-finger horizontal trackpad swipe
/// over it switches profiles (Arc) instead of scrolling; vertical scrolling
/// is unchanged. One switch per gesture (`ProfileSwipeTracker`).
final class SidebarScrollView: NSScrollView {
    /// Called with -1 (previous) or +1 (next) once per qualifying swipe.
    var onHorizontalSwipe: ((Int) -> Void)?
    private var tracker = ProfileSwipeTracker()

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, let phase = Self.phase(of: event) else {
            super.scrollWheel(with: event)
            return
        }
        if let step = tracker.feed(deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY), phase: phase) {
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
