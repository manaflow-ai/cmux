/// One normalized touch event sent to a Simulator surface.
public struct ControlSimulatorTouch: Sendable, Equatable {
    /// The touch lifecycle phase, such as `began`, `moved`, or `ended`.
    public let phase: String
    /// The primary horizontal coordinate in the closed range from zero to one.
    public let x: Double
    /// The primary vertical coordinate in the closed range from zero to one.
    public let y: Double
    /// The optional secondary horizontal coordinate for multitouch input.
    public let secondX: Double?
    /// The optional secondary vertical coordinate for multitouch input.
    public let secondY: Double?
    /// The named screen edge associated with an edge gesture.
    public let edge: String

    /// Creates one normalized touch event.
    public init(
        phase: String,
        x: Double,
        y: Double,
        secondX: Double? = nil,
        secondY: Double? = nil,
        edge: String = "none"
    ) {
        self.phase = phase
        self.x = x
        self.y = y
        self.secondX = secondX
        self.secondY = secondY
        self.edge = edge
    }
}
