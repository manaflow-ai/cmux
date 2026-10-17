public import Foundation

/// Optional bounded binary transfer over a conversation's authorized scope.
public protocol ConversationArtifactClient: ConversationClient {
    /// Reads a pinned artifact chunk; never reads a client-supplied file path.
    func artifactChunk(_ query: ConversationArtifactQuery) async throws -> ConversationArtifactChunk
}

/// Identifies a journaled artifact and a resumable offset.
public struct ConversationArtifactQuery: Codable, Sendable {
    public let sessionID: ConversationID
    public let artifactID: String
    public let offset: UInt64
    public let expectedSHA256: String?

    public init(sessionID: ConversationID, artifactID: String, offset: UInt64 = 0, expectedSHA256: String? = nil) {
        self.sessionID = sessionID
        self.artifactID = artifactID
        self.offset = offset
        self.expectedSHA256 = expectedSHA256
    }
}

/// A chunk of at most 64 KiB from one immutable artifact version.
public struct ConversationArtifactChunk: Codable, Sendable {
    public let artifactID: String
    public let fileName: String
    public let offset: UInt64
    public let totalBytes: UInt64
    public let sha256: String
    public let data: Data

    public init(artifactID: String, fileName: String, offset: UInt64, totalBytes: UInt64, sha256: String, data: Data) {
        self.artifactID = artifactID
        self.fileName = fileName
        self.offset = offset
        self.totalBytes = totalBytes
        self.sha256 = sha256
        self.data = data
    }
}
