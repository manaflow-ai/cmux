/// A process-safe rectangle expressed in host-view points.
public struct SimulatorRect: Codable, Equatable, Sendable {
    /// The leading coordinate.
    public let x: Double
    /// The bottom coordinate.
    public let y: Double
    /// The rectangle width.
    public let width: Double
    /// The rectangle height.
    public let height: Double

    /// Creates a rectangle.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
