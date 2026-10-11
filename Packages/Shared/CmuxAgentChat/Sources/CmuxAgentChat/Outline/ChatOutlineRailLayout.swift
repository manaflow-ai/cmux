import Foundation

/// Vertical placement of turn ticks on a rail of fixed height.
///
/// Ticks sit at a comfortable fixed spacing, centered on the rail. When the
/// turns don't fit, spacing compresses to fill the rail; below
/// ``minimumDrawnSpacing`` only every n-th tick is drawn, but hovering still
/// resolves every turn, so hundreds of turns stay reachable.
public struct ChatOutlineRailLayout: Sendable, Equatable {
    /// Spacing between ticks when every turn fits.
    public static let preferredSpacing = 8.0
    /// Smallest spacing at which every tick is drawn.
    public static let minimumDrawnSpacing = 3.0
    /// Empty space kept above the first and below the last tick.
    public static let verticalInset = 12.0

    /// Number of turns.
    public let count: Int
    /// Rail height in points.
    public let height: Double
    /// Distance between consecutive turns, in points.
    public let spacing: Double
    /// Y of the first turn, measured from the top.
    public let firstY: Double

    /// Lays out `count` turns on a rail `height` points tall.
    public init(count: Int, height: Double) {
        self.count = max(0, count)
        self.height = max(0, height)
        let usable = max(0, self.height - 2 * Self.verticalInset)
        if self.count <= 1 {
            spacing = Self.preferredSpacing
            firstY = self.height / 2
        } else {
            let fitted = usable / Double(self.count - 1)
            spacing = min(Self.preferredSpacing, fitted)
            firstY = (self.height - spacing * Double(self.count - 1)) / 2
        }
    }

    /// Y of turn `index`, measured from the top.
    public func y(for index: Int) -> Double {
        firstY + Double(index) * spacing
    }

    /// Every how many turns a tick is drawn (1 when all fit).
    public var drawStride: Int {
        guard spacing > 0, spacing < Self.minimumDrawnSpacing else { return 1 }
        return Int((Self.minimumDrawnSpacing / spacing).rounded(.up))
    }

    /// Turn indices to draw, always including `highlighted` and the last turn.
    public func drawnIndices(highlighted: Int?) -> [Int] {
        guard count > 0 else { return [] }
        let stride = drawStride
        guard stride > 1 else { return Array(0..<count) }
        var indices = Array(Swift.stride(from: 0, to: count, by: stride))
        if indices.last != count - 1 { indices.append(count - 1) }
        if let highlighted, highlighted >= 0, highlighted < count, highlighted % stride != 0 {
            indices.append(highlighted)
            indices.sort()
        }
        return indices
    }

    /// The turn nearest to a hover or click at `y`, or `nil` when `y` is
    /// outside the tick block by more than `slop` points.
    public func index(atY y: Double, slop: Double = 8) -> Int? {
        guard count > 0 else { return nil }
        let lastY = self.y(for: count - 1)
        guard y >= firstY - slop, y <= lastY + slop else { return nil }
        guard count > 1, spacing > 0 else { return 0 }
        let raw = ((y - firstY) / spacing).rounded()
        return min(max(Int(raw), 0), count - 1)
    }
}
