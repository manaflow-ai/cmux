/// The private-route disclosure policy for a scannable attach payload.
///
/// Callers must choose explicitly so adding a route to a ticket cannot silently
/// add it to a QR code. The legacy mode exists only while released clients still
/// require Tailscale host routes during the Iroh migration.
public enum CmxPairingRouteDisclosureMode: Equatable, Sendable {
    /// Encode only Iroh EndpointIDs. All Iroh hints and every host/port or URL
    /// route are removed.
    case irohIdentityOnly
    /// Preserve the pre-Iroh compact route grammar for released clients.
    /// This may disclose private-network routes and must not become a default.
    case legacyPrivateNetworkCompatibility
}
