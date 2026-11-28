/// A redacted description of the live Iroh path safe for application settings.
///
/// The value deliberately excludes IP addresses, ports, relay URLs, and Iroh
/// path identifiers. Relay labels come only from the verified effective policy.
public enum CmxIrohSelectedTransportPath: Equatable, Sendable {
    /// No attributable live connection path is available.
    case unavailable

    /// Application traffic is using a direct public peer-to-peer path.
    case direct

    /// Application traffic is using a private or local network path.
    case privateNetwork

    /// Application traffic is using a relay from the signed managed catalog.
    ///
    /// - Parameters:
    ///   - provider: The provider label from the signed policy.
    ///   - region: The region label from the signed policy.
    case managedRelay(provider: String, region: String)

    /// Application traffic is using an account-defined custom relay.
    ///
    /// - Parameters:
    ///   - displayName: The user-supplied display name, or stable relay ID.
    ///   - provider: The user-supplied provider label.
    ///   - region: The user-supplied region label.
    case customRelay(displayName: String, provider: String, region: String)
}
