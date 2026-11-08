import Foundation

/// A rectangle reported by the design-mode runtime in CSS viewport points.
public struct BrowserDesignModeRect: Codable, Equatable, Sendable {
    /// The horizontal viewport coordinate.
    public let x: Double
    /// The vertical viewport coordinate.
    public let y: Double
    /// The rectangle width.
    public let width: Double
    /// The rectangle height.
    public let height: Double

    /// Creates a design-mode rectangle.
    /// - Parameters:
    ///   - x: The horizontal viewport coordinate.
    ///   - y: The vertical viewport coordinate.
    ///   - width: The rectangle width.
    ///   - height: The rectangle height.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
