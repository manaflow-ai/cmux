public import CoreGraphics

/// Turns two-finger scrolling over the phone's screen into one finger
/// dragging the screen, as scrolling works on a real phone. Trackpad scrolls
/// (with phases) become one continuous drag; a mouse wheel tick becomes a
/// short drag. Momentum after the fingers lift is ignored: the phone runs its
/// own deceleration once the finger leaves.
struct PhoneScrollGesture {
    /// Where a scroll is in its life, from `NSEvent.phase`.
    enum Phase {
        case began, changed, ended
        /// A mouse wheel tick (no phases).
        case wheel
    }

    private var current: CGPoint?

    /// The touches for one scroll event.
    /// - Parameters:
    ///   - point: where the pointer is, 0...1 on the screen (top-left origin).
    ///   - delta: the scroll in view points (`scrollingDeltaX/Y`; positive y moves content down).
    ///   - screen: the drawn screen's size in view points.
    mutating func touches(_ phase: Phase, at point: CGPoint, delta: CGVector, screen: CGSize) -> [(PhoneTouch.Phase, CGPoint)] {
        guard screen.width > 0, screen.height > 0 else { return [] }
        func moved(_ from: CGPoint, by delta: CGVector) -> CGPoint {
            CGPoint(x: min(max(from.x + delta.dx / screen.width, 0), 1), y: min(max(from.y + delta.dy / screen.height, 0), 1))
        }
        switch phase {
        case .began:
            current = point
            return [(.began, point)]
        case .changed:
            guard let from = current else { return [] }
            let to = moved(from, by: delta)
            current = to
            return [(.moved, to)]
        case .ended:
            guard let last = current else { return [] }
            current = nil
            return [(.ended, last)]
        case .wheel:
            guard current == nil else { return [] }
            let to = moved(point, by: CGVector(dx: delta.dx * 10, dy: delta.dy * 10))
            return [(.began, point), (.moved, to), (.ended, to)]
        }
    }
}
