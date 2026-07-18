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
            createdCandidates = stableItems.filter { $0.provenance == .created }
            attachedCandidates = stableItems.filter { $0.provenance == .attached }
            referencedCandidates = stableItems.filter { $0.provenance == .referenced }
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
            created: isSearch ? [] : statItems(pageCreated, includeDirectories: includeDirectories),
            createdTotal: createdCandidates.count,
            attached: isSearch ? [] : statItems(pageAttached, includeDirectories: includeDirectories),
            attachedTotal: attachedCandidates.count,
            referenced: statItems(pageReferenced, includeDirectories: includeDirectories),
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

    /// Counts immediate children for a gallery directory row without sorting
    /// or per-entry metadata, stopping at the shared listing limit so the cost
    /// never scales past the cap for large folders.
    private func directoryChildCount(path: String) -> (count: Int, isCapped: Bool)? {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [],
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return nil
        }
        var count = 0
        while enumerator.nextObject() != nil {
            count += 1
            if count > ArtifactByteReader.maximumDirectoryEntryCount {
                return (count: ArtifactByteReader.maximumDirectoryEntryCount, isCapped: true)
            }
        }
        return (count: count, isCapped: false)
    }

    private func statItems(
        _ references: [ChatArtifactIndexedReference],
        includeDirectories: Bool
    ) -> [ChatArtifactGalleryItem] {
        let reader = ArtifactByteReader()
        return references.compactMap { reference in
            do {
                let stat = try reader.stat(path: reference.path)
                guard includeDirectories || !stat.isDirectory else { return nil }
                let children = stat.isDirectory ? directoryChildCount(path: reference.path) : nil
                return ChatArtifactGalleryItem(
                    path: reference.path,
                    kind: stat.kind,
                    displayName: URL(fileURLWithPath: reference.path).lastPathComponent,
                    size: stat.size,
                    modifiedAt: stat.modifiedAt,
                    exists: stat.exists,
                    childCount: children?.count,
                    childCountIsCapped: children?.isCapped ?? false,
                    provenance: reference.provenance
                )
            } catch {
                return ChatArtifactGalleryItem(
                    path: reference.path,
                    kind: reader.kind(path: reference.path, isDirectory: false),
                    displayName: URL(fileURLWithPath: reference.path).lastPathComponent,
                    exists: false,
                    provenance: reference.provenance
                )
            }
        }
    }
}
