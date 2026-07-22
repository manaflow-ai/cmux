/// One stable page from a session-wide artifact gallery.
public struct ChatArtifactGalleryPage: Sendable, Equatable, Codable {
    /// Session that authorizes every returned path.
    public let sessionID: String
    /// Created paths in this page.
    public let created: [ChatArtifactGalleryItem]
    /// Total created paths in the stable snapshot.
    public let createdTotal: Int
    /// Attachment paths in this page.
    public let attached: [ChatArtifactGalleryItem]
    /// Total attachment paths in the stable snapshot.
    public let attachedTotal: Int
    /// Referenced page, or a flat all-provenance search-result page.
    public let referenced: [ChatArtifactGalleryItem]
    /// Total referenced count, or total search-result count for a query.
    public let referencedTotal: Int
    /// Opaque cursor for the next append-only page across all sections.
    public let nextCursor: String?
    /// Snapshot generation that served this response.
    public let generation: String
    /// Whether the request cursor belongs to an obsolete generation.
    public let requiresPagingRestart: Bool

    /// Creates one gallery response page.
    public init(
        sessionID: String,
        created: [ChatArtifactGalleryItem] = [],
        createdTotal: Int? = nil,
        attached: [ChatArtifactGalleryItem] = [],
        attachedTotal: Int? = nil,
        referenced: [ChatArtifactGalleryItem] = [],
        referencedTotal: Int = 0,
        nextCursor: String? = nil,
        generation: String = "",
        requiresPagingRestart: Bool = false
    ) {
        self.sessionID = sessionID
        self.created = created
        self.createdTotal = createdTotal ?? created.count
        self.attached = attached
        self.attachedTotal = attachedTotal ?? attached.count
        self.referenced = referenced
        self.referencedTotal = referencedTotal
        self.nextCursor = nextCursor
        self.generation = generation
        self.requiresPagingRestart = requiresPagingRestart
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case created
        case createdTotal = "created_total"
        case attached
        case attachedTotal = "attached_total"
        case referenced
        case referencedTotal = "referenced_total"
        case nextCursor = "next_cursor"
        case generation
        case requiresPagingRestart = "requires_paging_restart"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = (try? container.decode(String.self, forKey: .sessionID)) ?? ""
        created = (try? container.decode([ChatArtifactGalleryItem].self, forKey: .created)) ?? []
        createdTotal = (try? container.decode(Int.self, forKey: .createdTotal)) ?? created.count
        attached = (try? container.decode([ChatArtifactGalleryItem].self, forKey: .attached)) ?? []
        attachedTotal = (try? container.decode(Int.self, forKey: .attachedTotal)) ?? attached.count
        referenced = (try? container.decode([ChatArtifactGalleryItem].self, forKey: .referenced)) ?? []
        referencedTotal = (try? container.decode(Int.self, forKey: .referencedTotal)) ?? referenced.count
        nextCursor = try? container.decode(String.self, forKey: .nextCursor)
        generation = (try? container.decode(String.self, forKey: .generation)) ?? ""
        requiresPagingRestart = (try? container.decode(Bool.self, forKey: .requiresPagingRestart)) ?? false
    }

    /// Returns a compatibility view with directory rows removed.
    ///
    /// New clients use this when connected to a host that does not advertise
    /// folder gallery support.
    public func excludingDirectories() -> ChatArtifactGalleryPage {
        let filteredCreated = created.filter { $0.kind != .directory }
        let filteredAttached = attached.filter { $0.kind != .directory }
        let filteredReferenced = referenced.filter { $0.kind != .directory }
        return ChatArtifactGalleryPage(
            sessionID: sessionID,
            created: filteredCreated,
            createdTotal: max(0, createdTotal - (created.count - filteredCreated.count)),
            attached: filteredAttached,
            attachedTotal: max(0, attachedTotal - (attached.count - filteredAttached.count)),
            referenced: filteredReferenced,
            referencedTotal: max(0, referencedTotal - (referenced.count - filteredReferenced.count)),
            nextCursor: nextCursor,
            generation: generation,
            requiresPagingRestart: requiresPagingRestart
        )
    }
}
