/// One phase of a raw DeviceKit hardware-button interaction.
public struct SimulatorHIDButtonEvent: Codable, Equatable, Sendable {
    /// The raw HID usage delivered to CoreSimulator.
    public let button: SimulatorHIDButtonUsage
    /// Whether the hardware button is going down or up.
    public let phase: SimulatorKeyPhase

    /// Creates a raw hardware-button event.
    public init(button: SimulatorHIDButtonUsage, phase: SimulatorKeyPhase) {
        self.button = button
        self.phase = phase
    }
}
