/// A top-left-origin point normalized to the simulated display.
public struct SimulatorPoint: Codable, Equatable, Sendable {
    /// The horizontal ratio in `0...1`.
    public let x: Double
    /// The vertical ratio in `0...1`.
    public let y: Double

    /// Creates a normalized point and clamps both axes into `0...1`.
    public init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }
}
