import Foundation

/// Builds a mobile attach ticket that reaches a Mac through a local SSH tunnel.
public struct CmxSSHTunneledAttachTicket: Sendable {
    /// The host the local client dials.
    public let localHost: String
    /// The forwarded local port the local client dials.
    public let localPort: Int
    /// The remote host/port route the SSH server forwards to.
    public let remoteRoute: CmxAttachRoute
    /// The rewritten ticket containing the local loopback route.
    public let ticket: CmxAttachTicket

    /// Creates an SSH-tunneled ticket from a ticket minted by the remote Mac.
    ///
    /// - Parameters:
    ///   - ticket: The remote Mac attach ticket.
    ///   - localHost: Local host to advertise to the desktop client.
    ///   - localPort: Local SSH-forwarded port to advertise to the desktop client.
    ///   - supportedRemoteKinds: Remote route kinds that SSH can forward to.
    /// - Throws: ``CmxSSHTunneledAttachTicketError`` when no forwardable route exists.
    public init(
        ticket: CmxAttachTicket,
        localHost: String = "127.0.0.1",
        localPort: Int,
        supportedRemoteKinds: [CmxAttachTransportKind] = [.tailscale]
    ) throws {
        guard (1...65_535).contains(localPort) else {
            throw CmxSSHTunneledAttachTicketError.invalidLocalPort(localPort)
        }
        guard let remoteRoute = ticket.preferredRoute(supportedKinds: supportedRemoteKinds) else {
            throw CmxSSHTunneledAttachTicketError.noForwardableRemoteRoute
        }
        guard case .hostPort = remoteRoute.endpoint else {
            throw CmxSSHTunneledAttachTicketError.remoteRouteIsNotHostPort
        }

        let tunnelRoute = try CmxAttachRoute(
            id: "ssh_tunnel",
            kind: .debugLoopback,
            endpoint: .hostPort(host: localHost, port: localPort),
            priority: 0
        )
        self.localHost = localHost
        self.localPort = localPort
        self.remoteRoute = remoteRoute
        self.ticket = try CmxAttachTicket(
            version: ticket.version,
            workspaceID: ticket.workspaceID,
            terminalID: ticket.terminalID,
            macDeviceID: ticket.macDeviceID,
            macDisplayName: ticket.macDisplayName,
            macUserEmail: ticket.macUserEmail,
            macUserID: ticket.macUserID,
            macPairingCompatibilityVersion: ticket.macPairingCompatibilityVersion,
            macAppVersion: ticket.macAppVersion,
            macAppBuild: ticket.macAppBuild,
            routes: [tunnelRoute],
            expiresAt: ticket.expiresAt,
            authToken: ticket.authToken
        )
    }

    /// Encodes the rewritten ticket as a `cmux-ios://attach?...` URL.
    public func attachURL() throws -> URL {
        try ticket.attachURL()
    }
}

/// Errors raised while adapting an attach ticket to an SSH tunnel.
public enum CmxSSHTunneledAttachTicketError: Error, Equatable, Sendable {
    case invalidLocalPort(Int)
    case noForwardableRemoteRoute
    case remoteRouteIsNotHostPort
}

public extension CmxAttachTicket {
    /// Encodes this ticket as the mobile attach URL understood by existing mobile clients.
    func attachURL() throws -> URL {
        if let pairingURL = CmxPairingQRCode().encode(self), let url = URL(string: pairingURL) {
            return url
        }
        let data: Data
        if authToken != nil || expiresAt != nil {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(self)
        } else {
            data = try CmxAttachTicketCompactCoder().encode(self)
        }
        let payload = Self.base64URLEncode(data)
        guard let url = URL(string: "cmux-ios://attach?v=\(version)&payload=\(payload)") else {
            throw CmxAttachTicketAttachURLError.invalidURL
        }
        return url
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Errors raised while encoding an attach ticket URL.
public enum CmxAttachTicketAttachURLError: Error, Equatable, Sendable {
    case invalidURL
}
