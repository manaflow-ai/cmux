public import Foundation

/// A device signed in to the owner's account that can reach this server.
public nonisolated struct ServerDevice: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable, Codable { case mac, phone, web, cli }

    public var id: String
    public var name: String
    public var kind: Kind
    public var lastSeen: Date?

    public init(id: String, name: String, kind: Kind, lastSeen: Date?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.lastSeen = lastSeen
    }
}
