import Foundation

/// Builds stat-enriched, append-only pages from one transcript index snapshot.
public struct ChatArtifactGalleryBuilder: Sendable {
    /// Creates a gallery page builder.
    public init() {}

    /// Builds one sectioned or flat search page.
    ///
    /// - Parameters:
    ///   - sessionID: Session represented by the artifact index.
    ///   - items: De-duplicated transcript artifact references.
    ///   - orderedItems: Optional generation-cached stable ordering of `items`.
    ///   - generation: Stable snapshot generation carried by page cursors.
    ///   - cursor: Per-section positions after which paging continues.
    ///   - pageSize: Maximum entries to stat and include per section.
    ///   - query: Optional basename or path search.
    ///   - includeDirectories: Whether directory references are eligible for
    ///     rows. This defaults to `false` for clients without folder capability.
    /// - Returns: One gallery page with filesystem metadata.
    public func page(
        sessionID: String,
        items: [ChatArtifactIndexedReference],
        orderedItems: [ChatArtifactIndexedReference]? = nil,
        generation: String,
        cursor: ChatArtifactGalleryCursor?,
        pageSize: Int,
        query: String?,
        includeDirectories: Bool = false
    ) -> ChatArtifactGalleryPage {
        if let cursor, cursor.generation != generation {
            return ChatArtifactGalleryPage(
                sessionID: sessionID,
                generation: generation,
                requiresPagingRestart: true
            )
        }
        let ordering = ChatArtifactGalleryOrdering()
        let stableItems = orderedItems ?? ordering.sorted(items)
        let eligibility = ChatArtifactGalleryRowEligibility()
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearch = normalizedQuery?.isEmpty == false
        let createdCandidates: [ChatArtifactIndexedReference]
        let attachedCandidates: [ChatArtifactIndexedReference]
        let referencedCandidates: [ChatArtifactIndexedReference]
        if let normalizedQuery, !normalizedQuery.isEmpty {
            createdCandidates = []
            attachedCandidates = []
            referencedCandidates = ordering.matching(stableItems, query: normalizedQuery)
        } else {
            let candidates = eligibility.defaultCandidates(
                items,
                orderedItems: stableItems
            )
            createdCandidates = candidates.created
            attachedCandidates = candidates.attached
            referencedCandidates = candidates.referenced
        }
        let count = max(1, pageSize)
        let starts = pageStarts(
            cursor: cursor,
            created: createdCandidates,
            attached: attachedCandidates,
            referenced: referencedCandidates,
            ordering: ordering
        )
        // Sequential fill: a page extends the grouped list strictly at its
        // bottom (created, then attached, then referenced), so a
        // scroll-triggered load can never insert rows into a group the user
        // has already scrolled past.
        var remaining = count
        let pageCreated = Array(createdCandidates.dropFirst(starts.created).prefix(remaining))
        remaining -= pageCreated.count
        let pageAttached = Array(attachedCandidates.dropFirst(starts.attached).prefix(remaining))
        remaining -= pageAttached.count
        let pageReferenced = Array(referencedCandidates.dropFirst(starts.referenced).prefix(remaining))
        let nextCreatedOffset = starts.created + pageCreated.count
        let nextAttachedOffset = starts.attached + pageAttached.count
        let nextReferencedOffset = starts.referenced + pageReferenced.count
        let nextCursor: String?
        if nextCreatedOffset < createdCandidates.count
            || nextAttachedOffset < attachedCandidates.count
            || nextReferencedOffset < referencedCandidates.count {
            let last = pageReferenced.last
            nextCursor = try? ChatArtifactGalleryCursor(
                generation: generation,
                seq: last?.lastReferencedSeq ?? cursor?.seq ?? .max,
                path: last?.path ?? cursor?.path ?? "",
                createdOffset: nextCreatedOffset,
                attachedOffset: nextAttachedOffset,
                referencedOffset: nextReferencedOffset
            ).token()
        } else {
            nextCursor = nil
        }

        return ChatArtifactGalleryPage(
            sessionID: sessionID,
            created: isSearch ? [] : eligibility.rows(
                pageCreated,
                includeDirectories: includeDirectories,
                includeMissing: true
            ),
            createdTotal: createdCandidates.count,
            attached: isSearch ? [] : eligibility.rows(
                pageAttached,
                includeDirectories: includeDirectories,
                includeMissing: true
            ),
            attachedTotal: attachedCandidates.count,
            referenced: eligibility.rows(
                pageReferenced,
                includeDirectories: includeDirectories,
                includeMissing: true
            ),
            referencedTotal: referencedCandidates.count,
            nextCursor: nextCursor,
            generation: generation
        )
    }

    private func pageStarts(
        cursor: ChatArtifactGalleryCursor?,
        created: [ChatArtifactIndexedReference],
        attached: [ChatArtifactIndexedReference],
        referenced: [ChatArtifactIndexedReference],
        ordering: ChatArtifactGalleryOrdering
    ) -> (created: Int, attached: Int, referenced: Int) {
        guard let cursor else { return (0, 0, 0) }
        if let createdOffset = cursor.createdOffset,
           let attachedOffset = cursor.attachedOffset,
           let referencedOffset = cursor.referencedOffset {
            return (
                min(max(0, createdOffset), created.count),
                min(max(0, attachedOffset), attached.count),
                min(max(0, referencedOffset), referenced.count)
            )
        }
        let remaining = ordering.items(referenced, strictlyAfter: cursor)
        return (created.count, attached.count, referenced.count - remaining.count)
    }

}
