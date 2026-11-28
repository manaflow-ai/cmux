/// Origin and availability of the currently effective relay profile.
public enum CmxIrohRelayPolicySource: String, Codable, Equatable, Sendable {
    /// No account policy has been restored.
    case inactive

    /// A verified broker-managed relay profile is active.
    case managed

    /// A complete user-defined relay profile is active.
    case custom

    /// The requested managed selection cannot be honored.
    case managedUnavailable

    /// The requested custom selection cannot be honored.
    case customUnavailable
}
