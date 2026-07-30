/// Resolved normalized endpoints for one Simulator gesture.
public struct SimulatorUIAutomationGesturePoints: Equatable, Sendable {
    /// The normalized starting point.
    public let from: SimulatorPoint
    /// The normalized ending point.
    public let to: SimulatorPoint

    /// Creates normalized endpoints for one gesture.
    ///
    /// - Parameters:
    ///   - from: The normalized starting point.
    ///   - to: The normalized ending point.
    public init(from: SimulatorPoint, to: SimulatorPoint) {
        self.from = from
        self.to = to
    }
}
