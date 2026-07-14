/// Accumulated section rows and paging state for a session artifact gallery.
public struct ChatArtifactGallerySnapshot: Sendable, Equatable {
    /// Created artifact rows from the first page.
    public let created: [ChatArtifactGalleryItem]
    /// Attached artifact rows from the first page.
    public let attached: [ChatArtifactGalleryItem]
    /// Referenced artifact rows accumulated across pages.
    public let referenced: [ChatArtifactGalleryItem]
    /// Complete referenced-row count reported by the host.
    public let referencedTotal: Int
    /// Cursor for the next referenced page.
    public let nextCursor: String?
    /// Host snapshot generation that served the latest page.
    public let generation: String

    /// Whether the complete gallery has no rows.
    public var isEmpty: Bool {
        created.isEmpty && attached.isEmpty && referencedTotal == 0
    }

    /// Creates an accumulated snapshot from a first gallery page.
    ///
    /// - Parameter page: The first sectioned gallery page.
    public init(page: ChatArtifactGalleryPage) {
        created = page.created
        attached = page.attached
        referenced = page.referenced
        referencedTotal = page.referencedTotal
        nextCursor = page.nextCursor
        generation = page.generation
    }

    /// Appends a referenced page while dropping paths already in any section.
    ///
    /// First-seen order is preserved both across pages and within `page`.
    ///
    /// - Parameter page: The next referenced gallery page.
    /// - Returns: A snapshot containing only path-unique appended rows.
    public func appending(_ page: ChatArtifactGalleryPage) -> ChatArtifactGallerySnapshot {
        var seenPaths = Set((created + attached + referenced).map(\.path))
        let uniqueReferenced = page.referenced.filter { item in
            seenPaths.insert(item.path).inserted
        }
        return ChatArtifactGallerySnapshot(
            created: created,
            attached: attached,
            referenced: referenced + uniqueReferenced,
            referencedTotal: page.referencedTotal,
            nextCursor: page.nextCursor,
            generation: page.generation
        )
    }

    func limitingReferenced(to maximumCount: Int) -> ChatArtifactGallerySnapshot {
        ChatArtifactGallerySnapshot(
            created: created,
            attached: attached,
            referenced: Array(referenced.prefix(max(0, maximumCount))),
            referencedTotal: referencedTotal,
            nextCursor: nextCursor,
            generation: generation
        )
    }

    private init(
        created: [ChatArtifactGalleryItem],
        attached: [ChatArtifactGalleryItem],
        referenced: [ChatArtifactGalleryItem],
        referencedTotal: Int,
        nextCursor: String?,
        generation: String
    ) {
        self.created = created
        self.attached = attached
        self.referenced = referenced
        self.referencedTotal = referencedTotal
        self.nextCursor = nextCursor
        self.generation = generation
    }
}
