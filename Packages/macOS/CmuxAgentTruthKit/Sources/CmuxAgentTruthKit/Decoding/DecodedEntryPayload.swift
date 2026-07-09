import Foundation

/// Holds rich decoded transcript content that ``EntryContent`` cannot carry yet.
public struct DecodedEntryPayload: Hashable, Sendable {
    /// A stable hash of the decoded content.
    public let contentHash: Int
    /// A short display summary.
    public let summary: String
    /// The raw JSONL line or raw block JSON, when available.
    public let raw: String?

    /// Creates a decoded entry payload.
    /// - Parameters:
    ///   - contentHash: The stable content hash.
    ///   - summary: A short display summary.
    ///   - raw: The raw source content, when available.
    public init(contentHash: Int, summary: String, raw: String?) {
        self.contentHash = contentHash
        self.summary = summary
        self.raw = raw
    }
}
