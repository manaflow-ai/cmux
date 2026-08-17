/// The lifecycle state reported for a Simulator device.
public enum SimulatorDeviceState: String, Codable, Sendable {
    /// The device is not running.
    case shutdown = "Shutdown"
    /// The device is starting.
    case booting = "Booting"
    /// The device is ready for attachment.
    case booted = "Booted"
    /// The device is stopping.
    case shuttingDown = "Shutting Down"
    /// The installed Xcode reported an unrecognized state.
    case unknown

    /// Creates a resilient state value from `simctl` output.
    /// - Parameter rawState: The state string emitted by `simctl`.
    public init(simctlState rawState: String) {
        self = Self(rawValue: rawState) ?? .unknown
    }
}
