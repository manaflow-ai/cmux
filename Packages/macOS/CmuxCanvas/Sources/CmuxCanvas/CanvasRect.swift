import Foundation

/// An axis-aligned rectangle in canvas coordinates (y-down).
///
/// `CanvasRect` is the unit of pane geometry throughout the canvas model.
/// Width and height are expected to be non-negative; mutating operations in
/// the model clamp against ``CanvasMetrics/minPaneSize`` rather than allowing
/// degenerate rects.
public struct CanvasRect: Hashable, Codable, Sendable {
    /// The minimum-x (left) edge.
    public var x: Double
    /// The minimum-y (top) edge, since the canvas space is y-down.
    public var y: Double
    /// Width in canvas points.
    public var width: Double
    /// Height in canvas points.
    public var height: Double

    /// The zero rect.
    public static let zero = CanvasRect(x: 0, y: 0, width: 0, height: 0)

    /// Creates a rectangle from origin and size components.
    ///
    /// - Parameters:
    ///   - x: Left edge.
    ///   - y: Top edge (y-down space).
    ///   - width: Width in canvas points.
    ///   - height: Height in canvas points.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Creates a rectangle from an origin point and a size.
    ///
    /// - Parameters:
    ///   - origin: The top-left corner.
    ///   - size: The rectangle size.
    public init(origin: CanvasPoint, size: CanvasSize) {
        self.init(x: origin.x, y: origin.y, width: size.width, height: size.height)
    }

    /// The left edge.
    public var minX: Double { x }
    /// The right edge.
    public var maxX: Double { x + width }
    /// The horizontal center.
    public var midX: Double { x + width / 2 }
    /// The top edge (y-down space).
    public var minY: Double { y }
    /// The bottom edge (y-down space).
    public var maxY: Double { y + height }
    /// The vertical center.
    public var midY: Double { y + height / 2 }

    /// The top-left corner.
    public var origin: CanvasPoint {
        get { CanvasPoint(x: x, y: y) }
        set {
            x = newValue.x
            y = newValue.y
        }
    }

    /// The rectangle size.
    public var size: CanvasSize {
        get { CanvasSize(width: width, height: height) }
        set {
            width = newValue.width
            height = newValue.height
        }
    }

    /// The center point.
    public var center: CanvasPoint { CanvasPoint(x: midX, y: midY) }

    /// Returns this rect translated by the given deltas.
    ///
    /// - Parameters:
    ///   - dx: Horizontal translation.
    ///   - dy: Vertical translation.
    /// - Returns: The translated rect.
    public func offsetBy(dx: Double, dy: Double) -> CanvasRect {
        CanvasRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// Returns this rect grown outward on every edge.
    ///
    /// - Parameter amount: Distance to grow each edge by. Negative values shrink.
    /// - Returns: The expanded rect.
    public func expandedBy(_ amount: Double) -> CanvasRect {
        CanvasRect(
            x: x - amount,
            y: y - amount,
            width: width + amount * 2,
            height: height + amount * 2
        )
    }

    /// Whether this rect and `other` overlap with positive area.
    ///
    /// Rects that merely touch along an edge do not intersect.
    ///
    /// - Parameter other: The rect to test against.
    /// - Returns: `true` when the rects share interior area.
    public func intersects(_ other: CanvasRect) -> Bool {
        minX < other.maxX && other.minX < maxX &&
            minY < other.maxY && other.minY < maxY
    }

    /// Whether the given point lies inside the rect (closed on min edges, open on max edges).
    ///
    /// - Parameter point: The point to test.
    /// - Returns: `true` when the point is inside.
    public func contains(_ point: CanvasPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    /// The smallest rect containing both this rect and `other`.
    ///
    /// - Parameter other: The rect to merge with.
    /// - Returns: The union rect.
    public func union(_ other: CanvasRect) -> CanvasRect {
        let nx = Swift.min(minX, other.minX)
        let ny = Swift.min(minY, other.minY)
        return CanvasRect(
            x: nx,
            y: ny,
            width: Swift.max(maxX, other.maxX) - nx,
            height: Swift.max(maxY, other.maxY) - ny
        )
    }

    /// The horizontal extent as a closed range.
    public var horizontalRange: ClosedRange<Double> { minX...Swift.max(minX, maxX) }
    /// The vertical extent as a closed range.
    public var verticalRange: ClosedRange<Double> { minY...Swift.max(minY, maxY) }
}
