import Foundation

/// A CRDT text operation broadcast between peers.
public enum TextOperation: Codable, Equatable, Sendable {
    /// Inserts one character after the referenced predecessor.
    case insert(id: CharacterID, after: CharacterID?, value: String)
    /// Deletes an existing character by tombstoning its identifier.
    case delete(id: CharacterID)
}
