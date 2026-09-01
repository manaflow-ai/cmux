/// A capped listing of one Mac-hosted artifact directory.
public struct ChatArtifactDirectoryListing: Sendable, Equatable, Codable {
    /// Directory entries sorted by name.
    public let entries: [ChatArtifactDirectoryEntry]
    /// Whether additional immediate children were omitted by the server cap.
    public let isTruncated: Bool
    /// Whether one or more retained names could not be read consistently.
    public let isIncomplete: Bool

    /// Creates a directory listing.
    ///
    /// - Parameters:
    ///   - entries: Directory entries sorted by name.
    ///   - isTruncated: Whether the server omitted additional entries.
    ///   - isIncomplete: Whether a child changed or became unreadable while listing.
    public init(
        entries: [ChatArtifactDirectoryEntry],
        isTruncated: Bool = false,
        isIncomplete: Bool = false
    ) {
        self.entries = entries
        self.isTruncated = isTruncated
        self.isIncomplete = isIncomplete
    }

    private enum CodingKeys: String, CodingKey {
        case entries
        case isTruncated = "is_truncated"
        case isIncomplete = "is_incomplete"
    }

    /// Decodes listings from current and legacy hosts.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([ChatArtifactDirectoryEntry].self, forKey: .entries)
        isTruncated = try container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
        isIncomplete = try container.decodeIfPresent(Bool.self, forKey: .isIncomplete) ?? false
    }

    /// Encodes the capped-list metadata for mobile clients.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(isTruncated, forKey: .isTruncated)
        try container.encode(isIncomplete, forKey: .isIncomplete)
    }
}
