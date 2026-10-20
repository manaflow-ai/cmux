import Foundation

/// A point in canvas coordinates.
///
/// The canvas coordinate space is y-down: `y` grows toward the bottom of the
/// canvas, matching a flipped AppKit document view and UIKit. All canvas
/// geometry is `Double`-based so the model stays deterministic and
/// platform-neutral (no CoreGraphics dependency).
public struct CanvasPoint: Hashable, Codable, Sendable {
    /// Horizontal coordinate in canvas points.
    public var x: Double
    /// Vertical coordinate in canvas points (grows downward).
    public var y: Double

    /// The origin point `(0, 0)`.
    public static let zero = CanvasPoint(x: 0, y: 0)

    /// Creates a point.
    ///
    /// - Parameters:
    ///   - x: Horizontal coordinate in canvas points.
    ///   - y: Vertical coordinate in canvas points (grows downward).
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// Returns this point translated by the given deltas.
    ///
    /// - Parameters:
    ///   - dx: Horizontal translation.
    ///   - dy: Vertical translation.
    /// - Returns: The translated point.
    public func offsetBy(dx: Double, dy: Double) -> CanvasPoint {
        CanvasPoint(x: x + dx, y: y + dy)
    }
}
