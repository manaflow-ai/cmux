import Foundation

/// One stored element in the collaboration text CRDT.
struct TextElement: Codable, Equatable, Sendable {
    let id: CharacterID
    let after: CharacterID?
    let value: String
    var isDeleted: Bool
}
