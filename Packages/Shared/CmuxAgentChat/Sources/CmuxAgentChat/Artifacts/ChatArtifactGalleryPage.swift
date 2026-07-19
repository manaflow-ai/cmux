/// One stable page from a session-wide artifact gallery.
public struct ChatArtifactGalleryPage: Sendable, Equatable, Codable {
    /// Session that authorizes every returned path.
    public let sessionID: String
    /// Complete created paths, present only on the first sectioned page.
    public let created: [ChatArtifactGalleryItem]
    /// Complete attachment paths, present only on the first sectioned page.
    public let attached: [ChatArtifactGalleryItem]
    /// Referenced page, or a flat all-provenance search-result page.
    public let referenced: [ChatArtifactGalleryItem]
    /// Total referenced count, or total search-result count for a query.
    public let referencedTotal: Int
    /// Opaque cursor for the next append-only page.
    public let nextCursor: String?
    /// Snapshot generation that served this response.
    public let generation: String

    /// Creates one gallery response page.
    public init(
        sessionID: String,
        created: [ChatArtifactGalleryItem] = [],
        attached: [ChatArtifactGalleryItem] = [],
        referenced: [ChatArtifactGalleryItem] = [],
        referencedTotal: Int = 0,
        nextCursor: String? = nil,
        generation: String = ""
    ) {
        self.sessionID = sessionID
        self.created = created
        self.attached = attached
        self.referenced = referenced
        self.referencedTotal = referencedTotal
        self.nextCursor = nextCursor
        self.generation = generation
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case created
        case attached
        case referenced
        case referencedTotal = "referenced_total"
        case nextCursor = "next_cursor"
        case generation
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = (try? container.decode(String.self, forKey: .sessionID)) ?? ""
        created = (try? container.decode([ChatArtifactGalleryItem].self, forKey: .created)) ?? []
        attached = (try? container.decode([ChatArtifactGalleryItem].self, forKey: .attached)) ?? []
        referenced = (try? container.decode([ChatArtifactGalleryItem].self, forKey: .referenced)) ?? []
        referencedTotal = (try? container.decode(Int.self, forKey: .referencedTotal)) ?? referenced.count
        nextCursor = try? container.decode(String.self, forKey: .nextCursor)
        generation = (try? container.decode(String.self, forKey: .generation)) ?? ""
    }
}
