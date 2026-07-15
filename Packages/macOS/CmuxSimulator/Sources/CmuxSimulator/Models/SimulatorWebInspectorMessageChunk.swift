import Foundation

/// One bounded piece of a raw Web Inspector JSON message.
///
/// Consumers reassemble chunks with the same `messageID` in ascending
/// `sequence` order. A stream can process each chunk immediately instead of
/// allocating the complete message, which keeps heap snapshots below the
/// host-worker frame ceiling.
public struct SimulatorWebInspectorMessageChunk: Codable, Equatable, Sendable {
    /// Maximum response bytes transported from the worker to the UI.
    public static let maximumRetainedResponseBytes = 128 * 1_024
    /// Worker session that produced the message.
    public let sessionID: UUID
    /// Correlation identity shared by every chunk of one JSON message.
    public let messageID: UUID
    /// Zero-based chunk sequence.
    public let sequence: Int
    /// Whether this is the final chunk for `messageID`.
    public let isFinal: Bool
    /// Whether the worker omitted bytes after the retained prefix.
    public let isTruncated: Bool
    /// Raw top-level JSON request-id token extracted before truncation.
    public let requestIDToken: Data?
    /// Raw UTF-8 bytes. Splits may occur between Unicode scalar boundaries.
    public let payload: Data

    /// Creates one ordered piece of a raw Web Inspector response.
    public init(
        sessionID: UUID,
        messageID: UUID,
        sequence: Int,
        isFinal: Bool,
        payload: Data,
        isTruncated: Bool = false,
        requestIDToken: Data? = nil
    ) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.sequence = sequence
        self.isFinal = isFinal
        self.isTruncated = isTruncated
        self.requestIDToken = requestIDToken
        self.payload = payload
    }
}
