/// A capped listing of one Mac-hosted artifact directory.
public struct ChatArtifactDirectoryListing: Sendable, Equatable, Codable {
    /// Directory entries sorted by name.
    public let entries: [ChatArtifactDirectoryEntry]
    /// Whether additional immediate children were omitted by the server cap.
    public let isTruncated: Bool

    /// Creates a directory listing.
    ///
    /// - Parameters:
    ///   - entries: Directory entries sorted by name.
    ///   - isTruncated: Whether the server omitted additional entries.
    public init(entries: [ChatArtifactDirectoryEntry], isTruncated: Bool = false) {
        self.entries = entries
        self.isTruncated = isTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case isTruncated = "is_truncated"
    }

    /// Decodes listings from current and legacy hosts.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([ChatArtifactDirectoryEntry].self, forKey: .entries)
        isTruncated = try container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
    }

    /// Encodes the capped-list metadata for mobile clients.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(isTruncated, forKey: .isTruncated)
    }
}
