import Foundation

/// Stable transcript sort key carried between gallery pages.
public struct ChatArtifactGalleryCursor: Sendable, Equatable, Codable {
    /// Snapshot generation that emitted the cursor.
    public let generation: String
    /// Last-reference sequence of the page's final row.
    public let seq: Int
    /// Path tie-breaker of the page's final row.
    public let path: String

    /// Creates a stable cursor.
    public init(generation: String, seq: Int, path: String) {
        self.generation = generation
        self.seq = seq
        self.path = path
    }

    /// Encodes this cursor as an opaque RPC token.
    public func token() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
    }

    /// Decodes an opaque RPC token.
    public init?(token: String) {
        guard let data = Data(base64Encoded: token),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else {
            return nil
        }
        self = decoded
    }
}
