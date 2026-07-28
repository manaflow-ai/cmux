/// A USB HID keyboard event sent to the simulated device.
public struct SimulatorKeyEvent: Codable, Equatable, Sendable {
    /// The USB HID usage-page 0x07 key code.
    public let usage: UInt32
    /// Whether the key is going down or up.
    public let phase: SimulatorKeyPhase

    /// Creates a keyboard event.
    public init(usage: UInt32, phase: SimulatorKeyPhase) {
        self.usage = usage
        self.phase = phase
    }
}
