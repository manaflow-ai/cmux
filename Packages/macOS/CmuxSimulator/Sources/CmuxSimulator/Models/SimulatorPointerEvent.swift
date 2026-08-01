/// A normalized single-touch or two-touch event sent to the Simulator worker.
public struct SimulatorPointerEvent: Codable, Equatable, Sendable {
    /// The touch phase.
    public let phase: SimulatorTouchPhase
    /// The first finger.
    public let primary: SimulatorPoint
    /// The optional second finger used for pinch and two-finger gestures.
    public let secondary: SimulatorPoint?
    /// The system edge attached to a single-finger gesture.
    public let edge: SimulatorEdge

    /// Creates a pointer event.
    public init(
        phase: SimulatorTouchPhase,
        primary: SimulatorPoint,
        secondary: SimulatorPoint? = nil,
        edge: SimulatorEdge = .none
    ) {
        self.phase = phase
        self.primary = primary
        self.secondary = secondary
        self.edge = edge
    }
}
