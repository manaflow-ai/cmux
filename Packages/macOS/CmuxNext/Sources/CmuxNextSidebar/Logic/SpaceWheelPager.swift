import Foundation

/// A mouse wheel over the spaces pages them like a paged scroll view: one
/// roll moves one space. A free-spinning or smooth-scrolling wheel sends a
/// roll as a burst of line events (6 to 48, at most 100 ms apart, recorded
/// 2026-10-09), so the burst pages once: the next page needs `quietGap`
/// without a wheel event that way, and a roll the other way pages at once.
/// A horizontal wheel (tilt, or Shift with a vertical wheel) pages; a
/// vertical one pages only where nothing scrolls vertically
/// (`pagesVertically`). Deltas follow the system's scroll direction, like
/// every scroll view: content moving left or up shows the next space.
nonisolated struct SpaceWheelPager: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Not a paging wheel: scroll as usual.
        case pass
        /// The rest of a roll that already paged: swallow it.
        case hold
        /// Page by -1 (previous space) or +1 (next space).
        case page(Int)
    }

    static let quietGap: TimeInterval = 0.15

    private var last: Step?
    private struct Step: Equatable, Sendable {
        var time: TimeInterval
        var direction: Int
    }

    mutating func feed(deltaX: CGFloat, deltaY: CGFloat, time: TimeInterval, pagesVertically: Bool) -> Outcome {
        let horizontal = abs(deltaX) > abs(deltaY)
        guard horizontal || pagesVertically else { return .pass }
        let delta = horizontal ? deltaX : deltaY
        guard delta != 0 else { return .hold }
        let direction = delta > 0 ? -1 : 1
        let sameRoll = last.map { $0.direction == direction && time - $0.time >= 0 && time - $0.time < Self.quietGap } ?? false
        last = Step(time: time, direction: direction)
        return sameRoll ? .hold : .page(direction)
    }
}
