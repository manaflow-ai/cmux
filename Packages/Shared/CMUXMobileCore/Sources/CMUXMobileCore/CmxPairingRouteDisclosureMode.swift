/// The private-route disclosure policy for a scannable attach payload.
///
/// Callers must choose explicitly so adding a route to a ticket cannot silently
/// add it to a QR code. The compatibility name is retained because its grammar
/// remains readable by released clients; the Mac pairing window uses it only
/// for the user-selected Tailscale path.
public enum CmxPairingRouteDisclosureMode: Equatable, Sendable {
    /// Preserve the original compact route grammar for a Tailscale pairing
    /// code. This discloses the selected tailnet destination.
    case legacyPrivateNetworkCompatibility
}
