import Foundation

/// A visible snapshot of a collaboration document.
public struct CollaborationDocumentSnapshot: Codable, Equatable, Sendable {
    /// The stable document identifier.
    public let documentID: String
    /// The current CRDT-resolved text.
    public let text: String
    /// A deterministic hash of the current text.
    public let textHash: String

    /// Creates a document snapshot.
    /// - Parameters:
    ///   - documentID: The stable document identifier.
    ///   - text: The current CRDT-resolved text.
    ///   - textHash: A deterministic hash of the current text.
    public init(documentID: String, text: String, textHash: String) {
        self.documentID = documentID
        self.text = text
        self.textHash = textHash
    }
}
