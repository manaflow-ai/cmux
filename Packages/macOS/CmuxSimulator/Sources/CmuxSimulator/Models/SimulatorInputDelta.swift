/// A normalized vector in Simulator display coordinates.
public struct SimulatorInputDelta: Equatable, Sendable {
    /// Horizontal movement, positive toward the display's right edge.
    public let x: Double
    /// Vertical movement, positive toward the display's bottom edge.
    public let y: Double

    /// Creates an input movement vector.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
