/// Validation failures for a managed Iroh relay credential.
public enum CmxIrohRelayConfigurationError: Error, Equatable, Sendable {
    /// The relay URL is not a canonical HTTPS origin ending in `/`.
    case invalidURL

    /// The RCAN token is empty, too large, or not lowercase unpadded Base32.
    case invalidToken

    /// The token expiry or refresh schedule is already invalid when decoded.
    case invalidLifetime
}
