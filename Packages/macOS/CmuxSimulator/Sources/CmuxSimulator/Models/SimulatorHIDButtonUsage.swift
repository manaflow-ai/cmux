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
