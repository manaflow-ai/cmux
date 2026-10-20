/// One finger event sent to a simulator: a phase and a point normalized to
/// the screen (0...1, top-left origin, in the displayed orientation), at a
/// time offset from the gesture's start.
public struct PhoneTouch: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        case began, moved, ended
    }

    public var phase: Phase
    public var x: Double
    public var y: Double
    /// When to send it, from the first event of the gesture.
    public var offset: Duration

    public init(phase: Phase, x: Double, y: Double, offset: Duration) {
        self.phase = phase
        self.x = x
        self.y = y
        self.offset = offset
    }
}
