import Foundation

/// Holds id-stable entry content and its wire-carriable payload.
public struct EntryContent: Codable, Hashable, Sendable {
    /// The stable content hash used for identity and replacement checks.
    public let contentHash: Int
    /// The rich transcript payload carried with the entry.
    public let payload: EntryPayload

    private enum CodingKeys: String, CodingKey {
        case contentHash
        case payload
    }

    /// Creates entry content with a producer-supplied content hash.
    /// - Parameters:
    ///   - contentHash: The id-stable content hash.
    ///   - payload: The rich transcript payload.
    public init(contentHash: Int, payload: EntryPayload) {
        self.contentHash = contentHash
        self.payload = payload
    }

    /// Decodes entry content, defaulting missing payloads to an unknown value for old replay logs.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.contentHash = try container.decode(Int.self, forKey: .contentHash)
        self.payload = (try? container.decode(EntryPayload.self, forKey: .payload)) ?? .unknown(UnknownPayload(rawKind: "unknown"))
    }

    /// Encodes entry content.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(payload, forKey: .payload)
    }
}
