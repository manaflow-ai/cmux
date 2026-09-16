import Foundation

/// The one current v2 cache for a complete device/build/team identity.
public struct V2CachedState: Codable, Sendable, Equatable {
    /// A format discriminator that prevents legacy state adoption.
    public let formatVersion: Int
    /// Full scope, checked against the requesting service on every load.
    public let identity: V2Identity
    /// Last committed registration; ordinary reconnects do not create another.
    public var device: V2DeviceRecord?
    /// Latest API credential; no history of issued tickets is retained.
    public var ticket: V2Ticket?
    /// One latest credential per configured relay URL.
    public var relayCredentials: [V2RelayCredential]
    /// Last complete permission-filtered directory, with its authority deadline.
    public var directory: V2Directory?
    /// Whether a known revocation invalidates all cached authority for this scope.
    public var authorityRevoked: Bool

    /// Starts an empty v2 cache without reading pre-v2 keys or credentials.
    /// - Parameter identity: The complete new authorization scope.
    public init(identity: V2Identity) {
        formatVersion = 2
        self.identity = identity
        device = nil
        ticket = nil
        relayCredentials = []
        directory = nil
        authorityRevoked = false
    }
}
