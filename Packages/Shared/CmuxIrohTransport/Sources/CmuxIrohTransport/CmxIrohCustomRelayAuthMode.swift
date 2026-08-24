/// Authentication required by a user-defined relay.
public enum CmxIrohCustomRelayAuthMode: String, Codable, Equatable, Sendable {
    /// The relay accepts unauthenticated clients.
    case none

    /// The device must supply a user-provided static token from secure storage.
    case staticToken = "device_secret"
}
