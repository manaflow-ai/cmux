import Foundation

/// The backend `CmuxRemoteEndpoint` returned by the Cloud attach API.
///
/// This is a data contract, not a transport implementation. The route may use
/// the owner's private WireGuard network. It is not the retired PTY/RPC lease
/// protocol and must not send a `{ token, session_id }` authentication frame.
public struct CmxCloudAttachEndpoint: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The required `cmux-remote` transport discriminator.
    public let transport: String
    /// The daemon link route, which may contain credentials and must not be logged.
    public let route: String
    /// The short-lived ingress or lease-ledger token, not a mobile account token.
    public let token: String
    /// Lease expiry in Unix seconds; non-positive values remain expired dates.
    public let expiresAtUnix: Double
    /// The daemon session name inside the machine.
    public let session: String
    /// Whether the authenticated control plane reports a trusted carrier listener.
    ///
    /// False requires the daemon's enrolled-device authentication. Neither the URL
    /// nor successful decoding can upgrade this to true.
    public let trustedCarrier: Bool
    /// Optional daemon identity used to diagnose client/server protocol mismatches.
    public let daemonBuild: CmxCloudDaemonBuild?
    /// Legacy enrollment metadata, retained when an older response includes it.
    public let invitation: CmxCloudAttachInvitation?
    /// Optional machine addresses on the owner's private network.
    public let networkAddresses: CmxCloudNetworkAddresses?

    /// The lease expiry as a date, including expired zero or negative timestamps.
    public var expiresAt: Date { Date(timeIntervalSince1970: expiresAtUnix) }

    /// A diagnostic summary that excludes the route, token, and invitation.
    public var description: String {
        "CmxCloudAttachEndpoint(transport: cmux-remote, expiresAtUnix: \(expiresAtUnix), trustedCarrier: \(trustedCarrier))"
    }

    /// The same redacted summary used by debug output.
    public var debugDescription: String { description }

    private enum CodingKeys: String, CodingKey {
        case transport, route, token, expiresAtUnix, session, trustedCarrier
        case daemonBuild, invitation, networkAddresses
    }

    /// Creates an endpoint from an authenticated Cloud response's fields.
    ///
    /// - Parameters:
    ///   - route: The daemon link route, potentially carrying credentials.
    ///   - token: The ingress or lease-ledger token.
    ///   - expiresAtUnix: The lease expiry in Unix seconds.
    ///   - session: The daemon session name.
    ///   - trustedCarrier: The explicit control-plane carrier trust flag.
    ///   - daemonBuild: Optional daemon build identity.
    ///   - invitation: Optional legacy enrollment metadata.
    ///   - networkAddresses: Optional private machine addresses.
    public init(
        route: String,
        token: String,
        expiresAtUnix: Double,
        session: String,
        trustedCarrier: Bool,
        daemonBuild: CmxCloudDaemonBuild? = nil,
        invitation: CmxCloudAttachInvitation? = nil,
        networkAddresses: CmxCloudNetworkAddresses? = nil
    ) {
        self.transport = CmxCloudAttach.remoteTransport
        self.route = route
        self.token = token
        self.expiresAtUnix = expiresAtUnix
        self.session = session
        self.trustedCarrier = trustedCarrier
        self.daemonBuild = daemonBuild
        self.invitation = invitation
        self.networkAddresses = networkAddresses
    }

    /// Decodes required fields without defaulting transport or carrier trust.
    ///
    /// - Parameter decoder: The decoder positioned at the response object.
    /// - Throws: `CmxCloudAttachError` for an unsupported transport, or
    ///   `DecodingError` for missing or malformed fields.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transport = try container.decode(String.self, forKey: .transport)
        guard transport == CmxCloudAttach.remoteTransport else {
            throw CmxCloudAttachError.unsupportedTransport(transport)
        }
        route = try container.decode(String.self, forKey: .route)
        token = try container.decode(String.self, forKey: .token)
        expiresAtUnix = try container.decode(Double.self, forKey: .expiresAtUnix)
        session = try container.decode(String.self, forKey: .session)
        trustedCarrier = try container.decode(Bool.self, forKey: .trustedCarrier)
        daemonBuild = try container.decodeIfPresent(CmxCloudDaemonBuild.self, forKey: .daemonBuild)
        invitation = try container.decodeIfPresent(CmxCloudAttachInvitation.self, forKey: .invitation)
        networkAddresses = try container.decodeIfPresent(CmxCloudNetworkAddresses.self, forKey: .networkAddresses)
    }
}
