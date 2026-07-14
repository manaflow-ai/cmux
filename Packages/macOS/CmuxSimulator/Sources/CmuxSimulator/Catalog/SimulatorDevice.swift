internal import Foundation

/// One iOS Simulator device from the local CoreSimulator device set.
public struct SimulatorDevice: Hashable, Sendable {
    /// The device's unique identifier; the only handle cmux uses to address it.
    public let udid: SimulatorDeviceUDID
    /// The user-visible device name, e.g. `"iPhone 17 Pro"`.
    public let name: String
    /// The device's lifecycle state at the time the catalog was captured.
    public let state: SimulatorDeviceState
    /// Whether the device's runtime is installed and usable.
    public let isAvailable: Bool
    /// The CoreSimulator runtime identifier, e.g.
    /// `"com.apple.CoreSimulator.SimRuntime.iOS-26-5"`.
    public let runtimeIdentifier: String
    /// The CoreSimulator device-type identifier, e.g.
    /// `"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"`, when reported.
    public let deviceTypeIdentifier: String?

    /// Creates a device record.
    ///
    /// - Parameters:
    ///   - udid: The device's unique identifier.
    ///   - name: The user-visible device name.
    ///   - state: The lifecycle state at capture time.
    ///   - isAvailable: Whether the device's runtime is installed and usable.
    ///   - runtimeIdentifier: The CoreSimulator runtime identifier.
    ///   - deviceTypeIdentifier: The CoreSimulator device-type identifier, if known.
    public init(
        udid: SimulatorDeviceUDID,
        name: String,
        state: SimulatorDeviceState,
        isAvailable: Bool,
        runtimeIdentifier: String,
        deviceTypeIdentifier: String? = nil
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.isAvailable = isAvailable
        self.runtimeIdentifier = runtimeIdentifier
        self.deviceTypeIdentifier = deviceTypeIdentifier
    }

    /// A short human-readable runtime name derived from the runtime
    /// identifier, e.g. `"iOS 26.5"`; falls back to the raw identifier.
    public var runtimeDisplayName: String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard runtimeIdentifier.hasPrefix(prefix) else { return runtimeIdentifier }
        let suffix = runtimeIdentifier.dropFirst(prefix.count)
        var parts = suffix.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return runtimeIdentifier }
        let platform = parts.removeFirst()
        guard !parts.isEmpty else { return platform }
        return "\(platform) \(parts.joined(separator: "."))"
    }
}
