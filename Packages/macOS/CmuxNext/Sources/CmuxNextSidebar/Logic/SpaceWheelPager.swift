import Foundation

/// A mouse wheel over the spaces pages them like a paged scroll view: one
/// notch moves one space, and a held or free-spinning wheel keeps paging at
/// most once per `interval` (a reverse notch pages at once). A horizontal
/// wheel (tilt, or Shift with a vertical wheel) always pages; a vertical one
/// pages only where it cannot scroll anything else (`pagesVertically`).
/// Deltas follow the content like a trackpad's: content moving left or up
/// shows the next space.
nonisolated struct SpaceWheelPager: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Not a paging wheel: scroll the list as usual.
        case pass
        /// A paging wheel inside `interval` of the last page: swallow it.
        case hold
        /// Page by -1 (previous space) or +1 (next space).
        case page(Int)
    }

    static let interval: TimeInterval = 0.25

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
        if let last, last.direction == direction, time - last.time >= 0, time - last.time < Self.interval { return .hold }
        last = Step(time: time, direction: direction)
        return .page(direction)
    }
}
