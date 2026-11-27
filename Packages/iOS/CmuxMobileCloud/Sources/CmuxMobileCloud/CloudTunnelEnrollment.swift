public import Foundation

/// The control plane's answer to `POST /api/vm/tunnel`: this device's peer on
/// the user's private network.
///
/// `clientConfig` is a complete wg-quick file with a blank `PrivateKey` line;
/// the device fills it from its Keychain (``WireGuardQuickConfig``).
public struct CloudTunnelEnrollment: Sendable, Equatable {
    /// The provider-side tunnel id.
    public var tunnelId: String
    /// The provider name.
    public var provider: String
    /// The device fingerprint the tunnel is bound to.
    public var deviceFingerprint: String
    /// The server-issued wg-quick config with the private key left blank.
    public var clientConfig: String
    /// The server's WireGuard public key.
    public var serverPublicKey: String
    /// The WireGuard endpoint host, when the server reports it separately.
    public var endpointHost: String?
    /// The WireGuard endpoint UDP port.
    public var endpointPort: Int
    /// CIDRs routed through the tunnel (the peer's `AllowedIPs`).
    public var routes: [String]
    /// This device's IPv4 address on the network, when assigned.
    public var addressV4: String?
    /// This device's IPv6 address on the network, when assigned.
    public var addressV6: String?
    /// Whether the server created the tunnel on this call.
    public var created: Bool
    /// Whether the server rotated the tunnel's keys to match this device.
    public var rotated: Bool

    /// Creates an enrollment record.
    public init(
        tunnelId: String,
        provider: String,
        deviceFingerprint: String,
        clientConfig: String,
        serverPublicKey: String,
        endpointHost: String?,
        endpointPort: Int,
        routes: [String],
        addressV4: String?,
        addressV6: String?,
        created: Bool,
        rotated: Bool
    ) {
        self.tunnelId = tunnelId
        self.provider = provider
        self.deviceFingerprint = deviceFingerprint
        self.clientConfig = clientConfig
        self.serverPublicKey = serverPublicKey
        self.endpointHost = endpointHost
        self.endpointPort = endpointPort
        self.routes = routes
        self.addressV4 = addressV4
        self.addressV6 = addressV6
        self.created = created
        self.rotated = rotated
    }
}
