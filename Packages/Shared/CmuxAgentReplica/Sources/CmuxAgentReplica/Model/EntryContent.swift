import Foundation

/// Holds id-stable opaque entry content for this slice.
public struct EntryContent: Codable, Hashable, Sendable {
    /// The stable content hash used for identity and replacement checks.
    public let contentHash: Int

    /// Creates an opaque entry content container.
    /// - Parameter contentHash: The id-stable content hash.
    public init(contentHash: Int) {
        self.contentHash = contentHash
    }
}
