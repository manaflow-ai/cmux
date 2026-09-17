import Foundation

/// One grapheme in the replicated TextBox sequence.
public struct WorkspaceShareTextAtom: Codable, Equatable, Sendable {
    /// Globally unique, deterministically sortable atom identifier.
    public let id: String
    /// Identifier after which this atom was inserted, or `nil` for the root.
    public let afterId: String?
    /// One extended grapheme cluster.
    public let value: String
    /// Whether a delete operation tombstoned this atom.
    public let deleted: Bool

    /// Creates a text atom.
    /// - Parameters:
    ///   - id: Globally unique atom identifier.
    ///   - afterId: Parent atom identifier.
    ///   - value: One extended grapheme cluster.
    ///   - deleted: Whether the atom is tombstoned.
    public init(id: String, afterId: String?, value: String, deleted: Bool = false) {
        self.id = id
        self.afterId = afterId
        self.value = value
        self.deleted = deleted
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case afterId
        case value
        case deleted
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        afterId = try container.decodeIfPresent(String.self, forKey: .afterId)
        value = try container.decode(String.self, forKey: .value)
        deleted = try container.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        if let afterId {
            try container.encode(afterId, forKey: .afterId)
        } else {
            try container.encodeNil(forKey: .afterId)
        }
        try container.encode(value, forKey: .value)
        try container.encode(deleted, forKey: .deleted)
    }
}
