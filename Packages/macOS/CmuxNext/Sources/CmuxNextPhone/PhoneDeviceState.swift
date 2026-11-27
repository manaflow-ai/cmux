/// Whether a phone can show its screen now.
public enum PhoneDeviceState: Sendable, Hashable, Codable {
    case shutdown
    case booting
    /// A simulator or VM that runs, or a real device that is connected.
    case ready
    /// A paired real device that is not reachable right now.
    case disconnected
    /// The backend lists the device but cannot run it (missing runtime, unsupported platform).
    case unavailable(reason: String)

    public var isReady: Bool { self == .ready }
}
