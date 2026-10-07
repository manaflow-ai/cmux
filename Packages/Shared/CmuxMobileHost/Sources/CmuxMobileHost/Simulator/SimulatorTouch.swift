/// One touch on a simulator screen, in device points.
public struct SimulatorTouch: Hashable, Sendable {
    public enum Phase: String, Hashable, Sendable {
        case began, moved, ended
    }

    public var phase: Phase
    public var x: Double
    public var y: Double

    public init(phase: Phase, x: Double, y: Double) {
        self.phase = phase
        self.x = x
        self.y = y
    }
}
