import CoreGraphics
import Foundation

/// While a selection handle, or the finger of a long-press drag, sits near
/// the top or bottom edge of the visible rows, the page scrolls toward that
/// edge, so a selection can reach rows that are not on screen, across the
/// whole scrollback (G-14, T-SEL-01). Like iOS text views: the deeper the
/// finger is in the edge zone (or past the edge), the faster the page moves.
/// Positions are points in the scroll view's frame (not its content).
public struct TerminalSelectionAutoscroll: Equatable, Sendable {
    /// Height of the zone at each edge where the page starts to move.
    public var edge: CGFloat = 48
    /// Speed (pt/s) at the zone's inner boundary and at the edge (or past it).
    public var minSpeed: CGFloat = 90
    public var maxSpeed: CGFloat = 2400

    public init() {}

    /// Scroll velocity in pt/s for a finger at `fingerY`, with the visible
    /// rows between `visibleTop` and `visibleBottom`: negative moves toward
    /// older rows (the top), positive toward the newest, 0 outside the zones.
    public func velocity(fingerY: CGFloat, visibleTop: CGFloat, visibleBottom: CGFloat) -> CGFloat {
        let height = visibleBottom - visibleTop
        guard height > 0 else { return 0 }
        // A short band (keyboard up) splits into two zones that never overlap.
        let zone = min(edge, height / 2)
        guard zone > 0 else { return 0 }
        func speed(_ depth: CGFloat) -> CGFloat {
            let d = min(1, max(0, depth))
            return minSpeed + (maxSpeed - minSpeed) * d * d
        }
        if fingerY < visibleTop + zone {
            return -speed((visibleTop + zone - fingerY) / zone)
        }
        if fingerY > visibleBottom - zone {
            return speed((fingerY - (visibleBottom - zone)) / zone)
        }
        return 0
    }

    /// The content offset after `dt` seconds at `velocity`, kept in `range`.
    public func step(offset: CGFloat, velocity: CGFloat, dt: TimeInterval, range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, offset + velocity * CGFloat(max(0, dt))))
    }
}
