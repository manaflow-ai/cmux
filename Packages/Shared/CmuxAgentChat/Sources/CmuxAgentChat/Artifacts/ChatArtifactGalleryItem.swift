import Foundation

/// One stat-enriched artifact returned by the session-wide gallery RPC.
public struct ChatArtifactGalleryItem: Sendable, Equatable, Codable, Identifiable {
    /// Absolute Mac host path.
    public let path: String
    /// Preview category inferred by the Mac.
    public let kind: ChatArtifactKind
    /// Basename presented by gallery rows.
    public let displayName: String
    /// Raw file size when the path exists and metadata is available.
    public let size: Int64?
    /// Last modification time when the path exists and metadata is available.
    public let modifiedAt: Date?
    /// Whether the path existed when this page was served.
    public let exists: Bool
    /// Immediate child count for a directory, when listing succeeded.
    public let childCount: Int?
    /// Whether ``childCount`` is the listing cap rather than the exact count.
    public let childCountIsCapped: Bool
    /// Transcript provenance after precedence-based de-duplication.
    public let provenance: ChatArtifactProvenance

    /// Stable row identity.
    public var id: String { path }

    /// Creates one gallery item.
    public init(
        path: String,
        kind: ChatArtifactKind,
        displayName: String,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        exists: Bool = true,
        childCount: Int? = nil,
        childCountIsCapped: Bool = false,
        provenance: ChatArtifactProvenance = .referenced
    ) {
        self.path = path
        self.kind = kind
        self.displayName = displayName
        self.size = size
        self.modifiedAt = modifiedAt
        self.exists = exists
        self.childCount = childCount
        self.childCountIsCapped = childCountIsCapped
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case kind
        case displayName = "display_name"
        case size
        case modifiedAt = "modified_at"
        case exists
        case childCount = "child_count"
        case childCountIsCapped = "child_count_is_capped"
        case provenance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        kind = (try? container.decode(ChatArtifactKind.self, forKey: .kind)) ?? .binary
        displayName = (try? container.decode(String.self, forKey: .displayName))
            ?? URL(fileURLWithPath: path).lastPathComponent
        size = try? container.decode(Int64.self, forKey: .size)
        if let seconds = try? container.decode(Double.self, forKey: .modifiedAt) {
            modifiedAt = Date(timeIntervalSince1970: seconds)
        } else {
            modifiedAt = try? container.decode(Date.self, forKey: .modifiedAt)
        }
        exists = (try? container.decode(Bool.self, forKey: .exists)) ?? true
        childCount = try? container.decode(Int.self, forKey: .childCount)
        childCountIsCapped = (try? container.decode(Bool.self, forKey: .childCountIsCapped)) ?? false
        provenance = (try? container.decode(ChatArtifactProvenance.self, forKey: .provenance)) ?? .referenced
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(kind, forKey: .kind)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(size, forKey: .size)
        if let modifiedAt {
            try container.encode(modifiedAt.timeIntervalSince1970, forKey: .modifiedAt)
        }
        try container.encode(exists, forKey: .exists)
        try container.encodeIfPresent(childCount, forKey: .childCount)
        try container.encode(childCountIsCapped, forKey: .childCountIsCapped)
        try container.encode(provenance, forKey: .provenance)
    }
}
