public import Foundation

/// The ICE servers for one connect, with the credentials' expiry.
public struct ICEConfiguration: Sendable, Hashable {
    public var servers: [ICEServer]
    /// When the TURN credentials stop working; nil for credential-free sets.
    public var expiresAt: Date?

    public init(servers: [ICEServer], expiresAt: Date? = nil) {
        self.servers = servers
        self.expiresAt = expiresAt
    }

    /// Whether this set can produce relayed (`.turn`) paths.
    public var hasTURN: Bool { servers.contains { $0.isTURN } }

    /// No servers: host candidates only (tests, same-LAN).
    public static let hostOnly = ICEConfiguration(servers: [])
    /// STUN only: P2P through NAT, no relay.
    public static let stunOnly = ICEConfiguration(servers: [.cloudflareSTUN])
}
