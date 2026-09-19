/// Trust policy for a host key that has not been seen by this device.
public enum MobileRemoteHostKeyPolicy: String, Codable, CaseIterable, Equatable, Sendable {
    /// Ask the user before accepting a new host key.
    case ask
    /// Require a matching saved fingerprint.
    case strict
}
