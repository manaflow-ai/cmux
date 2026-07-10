/// Identifies a raw HID button using DeviceKit's usage page and usage code.
public struct SimulatorHIDButtonUsage: Codable, Equatable, Hashable, Sendable {
    /// The HID usage page from DeviceKit's `chrome.json` metadata.
    public let page: UInt32
    /// The HID usage code from DeviceKit's `chrome.json` metadata.
    public let usage: UInt32

    /// Creates a raw DeviceKit HID button identifier.
    public init(page: UInt32, usage: UInt32) {
        self.page = page
        self.usage = usage
    }
}

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
