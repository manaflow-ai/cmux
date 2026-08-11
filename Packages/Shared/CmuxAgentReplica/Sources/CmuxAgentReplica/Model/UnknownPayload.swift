import Foundation

/// Carries fail-open transcript content that this version does not model.
public struct UnknownPayload: Codable, Hashable, Sendable {
    /// The maximum number of UTF-8 bytes retained for raw JSON.
    public static let rawJSONByteLimit = 8 * 1024

    /// The raw kind identifier.
    public let rawKind: String
    /// A compact human-readable summary, when available.
    public let summary: String?
    /// Bounded raw JSON for diagnostics and future reprocessing.
    public let rawJSON: String?
    /// Whether ``rawJSON`` was truncated to ``rawJSONByteLimit``.
    public let rawJSONTruncated: Bool

    private enum CodingKeys: String, CodingKey {
        case rawKind = "raw_kind"
        case summary
        case rawJSON = "raw_json"
        case rawJSONTruncated = "raw_json_truncated"
    }

    /// Creates an unknown payload, bounding raw JSON to 8 KB.
    /// - Parameters:
    ///   - rawKind: The raw kind identifier.
    ///   - summary: A compact human-readable summary, when available.
    ///   - rawJSON: Raw JSON for diagnostics and future reprocessing.
    ///   - rawJSONTruncated: Whether the provided raw JSON was already truncated.
    public init(rawKind: String, summary: String? = nil, rawJSON: String? = nil, rawJSONTruncated: Bool = false) {
        self.rawKind = rawKind
        self.summary = summary
        let bounded = UnknownPayload.bounded(rawJSON)
        self.rawJSON = bounded.value
        self.rawJSONTruncated = rawJSONTruncated || bounded.truncated
    }

    /// Decodes an unknown payload while bounding raw JSON.
    /// - Parameter decoder: The decoder to read from.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = (try? container.decode(String.self, forKey: .rawKind)) ?? "unknown"
        let summary = try? container.decodeIfPresent(String.self, forKey: .summary)
        let rawJSON = try? container.decodeIfPresent(String.self, forKey: .rawJSON)
        let rawJSONTruncated = (try? container.decodeIfPresent(Bool.self, forKey: .rawJSONTruncated)) ?? false
        self.init(rawKind: rawKind, summary: summary ?? nil, rawJSON: rawJSON ?? nil, rawJSONTruncated: rawJSONTruncated)
    }

    /// Encodes an unknown payload.
    /// - Parameter encoder: The encoder to write to.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawKind, forKey: .rawKind)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(rawJSON, forKey: .rawJSON)
        try container.encode(rawJSONTruncated, forKey: .rawJSONTruncated)
    }

    static func bounded(_ value: String?) -> (value: String?, truncated: Bool) {
        guard let value else {
            return (nil, false)
        }
        let bytes = Array(value.utf8)
        guard bytes.count > rawJSONByteLimit else {
            return (value, false)
        }
        let prefix = bytes.prefix(rawJSONByteLimit)
        return (String(decoding: prefix, as: UTF8.self), true)
    }
}
