import Foundation

/// A value snapshot describing one installed Simulator device.
public struct SimulatorDevice: Codable, Identifiable, Equatable, Hashable, Sendable {
    /// The CoreSimulator device identifier.
    public let id: String
    /// The display name configured for the device.
    public let name: String
    /// The CoreSimulator runtime identifier.
    public let runtimeIdentifier: String
    /// A user-facing runtime name, such as `iOS 26.5`.
    public let runtimeName: String
    /// The CoreSimulator device-type identifier.
    public let deviceTypeIdentifier: String
    /// The broad hardware family used to select controls and chrome.
    public let family: SimulatorDeviceFamily
    /// The current lifecycle state.
    public let state: SimulatorDeviceState
    /// Whether CoreSimulator says the device can run on this Mac.
    public let isAvailable: Bool
    /// The most recent boot timestamp when CoreSimulator supplied one.
    public let lastBootedAt: Date?

    /// Creates a Simulator device snapshot.
    public init(
        id: String,
        name: String,
        runtimeIdentifier: String,
        runtimeName: String,
        deviceTypeIdentifier: String,
        family: SimulatorDeviceFamily,
        state: SimulatorDeviceState,
        isAvailable: Bool,
        lastBootedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeName = runtimeName
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.family = family
        self.state = state
        self.isAvailable = isAvailable
        self.lastBootedAt = lastBootedAt
    }
}
