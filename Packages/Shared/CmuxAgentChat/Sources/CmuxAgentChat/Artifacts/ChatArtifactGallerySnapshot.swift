/// Accumulated section rows and paging state for a session artifact gallery.
public struct ChatArtifactGallerySnapshot: Sendable, Equatable {
    /// Created artifact rows accumulated across pages.
    public let created: [ChatArtifactGalleryItem]
    /// Complete created-row count reported by the host.
    public let createdTotal: Int
    /// Attached artifact rows accumulated across pages.
    public let attached: [ChatArtifactGalleryItem]
    /// Complete attached-row count reported by the host.
    public let attachedTotal: Int
    /// Referenced artifact rows accumulated across pages.
    public let referenced: [ChatArtifactGalleryItem]
    /// Complete referenced-row count reported by the host.
    public let referencedTotal: Int
    /// Cursor for the next page across any incomplete section.
    public let nextCursor: String?
    /// Host snapshot generation that served the latest page.
    public let generation: String

    /// Whether the complete gallery has no rows.
    public var isEmpty: Bool {
        createdTotal == 0 && attachedTotal == 0 && referencedTotal == 0
    }

    /// Creates an accumulated snapshot from a first gallery page.
    ///
    /// - Parameter page: The first sectioned gallery page.
    public init(page: ChatArtifactGalleryPage) {
        created = page.created
        createdTotal = page.createdTotal
        attached = page.attached
        attachedTotal = page.attachedTotal
        referenced = page.referenced
        referencedTotal = page.referencedTotal
        nextCursor = page.nextCursor
        generation = page.generation
    }

    /// Appends one sectioned page while dropping paths already in any section.
    ///
    /// First-seen order is preserved both across pages and within `page`.
    ///
    /// - Parameter page: The next sectioned gallery page.
    /// - Returns: A snapshot containing only path-unique appended rows.
    public func appending(_ page: ChatArtifactGalleryPage) -> ChatArtifactGallerySnapshot {
        guard !page.requiresPagingRestart else { return self }
        var seenPaths = Set((created + attached + referenced).map(\.path))
        let uniqueCreated = page.created.filter { item in
            seenPaths.insert(item.path).inserted
        }
        let uniqueAttached = page.attached.filter { item in
            seenPaths.insert(item.path).inserted
        }
        let uniqueReferenced = page.referenced.filter { item in
            seenPaths.insert(item.path).inserted
        }
        return ChatArtifactGallerySnapshot(
            created: created + uniqueCreated,
            createdTotal: page.createdTotal,
            attached: attached + uniqueAttached,
            attachedTotal: page.attachedTotal,
            referenced: referenced + uniqueReferenced,
            referencedTotal: page.referencedTotal,
            nextCursor: page.nextCursor,
            generation: page.generation
        )
    }

    /// Rebinds paging to a fresh first page without moving already visible rows.
    ///
    /// Existing rows retain their exact section order. Newly discovered first-page
    /// rows are appended, while the fresh generation and cursor become authoritative.
    /// This is used for background stale-cursor recovery where leading insertions
    /// could otherwise move the reader's scroll position.
    ///
    /// - Parameter fresh: First page from the current host generation.
    /// - Returns: A stable-order snapshot ready to continue fresh paging.
    public func restartingPaging(
        withFreshFirstPage fresh: ChatArtifactGallerySnapshot
    ) -> ChatArtifactGallerySnapshot {
        var seenPaths = Set((created + attached + referenced).map(\.path))
        let newCreated = fresh.created.filter { seenPaths.insert($0.path).inserted }
        let newAttached = fresh.attached.filter { seenPaths.insert($0.path).inserted }
        let newReferenced = fresh.referenced.filter { seenPaths.insert($0.path).inserted }
        return ChatArtifactGallerySnapshot(
            created: created + newCreated,
            createdTotal: max(fresh.createdTotal, created.count + newCreated.count),
            attached: attached + newAttached,
            attachedTotal: max(fresh.attachedTotal, attached.count + newAttached.count),
            referenced: referenced + newReferenced,
            referencedTotal: max(fresh.referencedTotal, referenced.count + newReferenced.count),
            nextCursor: fresh.nextCursor,
            generation: fresh.generation
        )
    }

    /// Adopts a fresh generation cursor without changing any visible row array.
    ///
    /// This supports a deferred live-refresh pill: paging can stop using the
    /// rejected cursor immediately while every rendered row remains fixed.
    ///
    /// - Parameter fresh: First page from the current host generation.
    /// - Returns: The unchanged rows with fresh totals and paging identity.
    public func rebasingPaging(
        ontoFreshFirstPage fresh: ChatArtifactGallerySnapshot
    ) -> ChatArtifactGallerySnapshot {
        ChatArtifactGallerySnapshot(
            created: created,
            createdTotal: max(fresh.createdTotal, created.count),
            attached: attached,
            attachedTotal: max(fresh.attachedTotal, attached.count),
            referenced: referenced,
            referencedTotal: max(fresh.referencedTotal, referenced.count),
            nextCursor: fresh.nextCursor,
            generation: fresh.generation
        )
    }

    /// Reconciles a newer first page without discarding rows already loaded.
    ///
    /// Fresh rows lead their provenance sections, while previously loaded rows
    /// retain their relative order. A path that moved between provenance
    /// sections appears only in the fresh section.
    ///
    /// - Parameter fresh: First-page snapshot from a newer host generation.
    /// - Returns: A generation-updated snapshot that preserves loaded history.
    public func reconciling(withFreshFirstPage fresh: ChatArtifactGallerySnapshot) -> ChatArtifactGallerySnapshot {
        var seenPaths: Set<String> = []
        let freshCreated = fresh.created.filter { seenPaths.insert($0.path).inserted }
        let freshAttached = fresh.attached.filter { seenPaths.insert($0.path).inserted }
        let freshReferenced = fresh.referenced.filter { seenPaths.insert($0.path).inserted }
        let retainedCreated = created.filter { seenPaths.insert($0.path).inserted }
        let retainedAttached = attached.filter { seenPaths.insert($0.path).inserted }
        let retainedReferenced = referenced.filter { seenPaths.insert($0.path).inserted }
        let mergedReferenced = freshReferenced + retainedReferenced
        return ChatArtifactGallerySnapshot(
            created: freshCreated + retainedCreated,
            createdTotal: max(fresh.createdTotal, freshCreated.count + retainedCreated.count),
            attached: freshAttached + retainedAttached,
            attachedTotal: max(fresh.attachedTotal, freshAttached.count + retainedAttached.count),
            referenced: mergedReferenced,
            referencedTotal: max(fresh.referencedTotal, mergedReferenced.count),
            nextCursor: fresh.nextCursor,
            generation: fresh.generation
        )
    }

    func limitingReferenced(to maximumCount: Int) -> ChatArtifactGallerySnapshot {
        ChatArtifactGallerySnapshot(
            created: created,
            createdTotal: createdTotal,
            attached: attached,
            attachedTotal: attachedTotal,
            referenced: Array(referenced.prefix(max(0, maximumCount))),
            referencedTotal: referencedTotal,
            nextCursor: nextCursor,
            generation: generation
        )
    }

    private init(
        created: [ChatArtifactGalleryItem],
        createdTotal: Int,
        attached: [ChatArtifactGalleryItem],
        attachedTotal: Int,
        referenced: [ChatArtifactGalleryItem],
        referencedTotal: Int,
        nextCursor: String?,
        generation: String
    ) {
        self.created = created
        self.createdTotal = createdTotal
        self.attached = attached
        self.attachedTotal = attachedTotal
        self.referenced = referenced
        self.referencedTotal = referencedTotal
        self.nextCursor = nextCursor
        self.generation = generation
    }
}
