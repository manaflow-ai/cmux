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
    ///   - generation: Stable snapshot generation carried by page cursors.
    ///   - cursor: Position after which the referenced section continues.
    ///   - pageSize: Maximum referenced entries to include.
    ///   - query: Optional basename or path search.
    ///   - includeDirectories: Whether directory references are eligible for
    ///     rows. This defaults to `false` for clients without folder capability.
    /// - Returns: One gallery page with filesystem metadata.
    public func page(
        sessionID: String,
        items: [ChatArtifactIndexedReference],
        generation: String,
        cursor: ChatArtifactGalleryCursor?,
        pageSize: Int,
        query: String?,
        includeDirectories: Bool = false
    ) -> ChatArtifactGalleryPage {
        let ordering = ChatArtifactGalleryOrdering()
        let eligibleItems = eligibleItems(items, includeDirectories: includeDirectories)
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearch = normalizedQuery?.isEmpty == false
        let candidates: [ChatArtifactIndexedReference]
        if let normalizedQuery, !normalizedQuery.isEmpty {
            candidates = ordering.search(eligibleItems, query: normalizedQuery)
        } else {
            candidates = ordering.sorted(eligibleItems.filter { $0.provenance == .referenced })
        }
        let remaining = ordering.items(candidates, strictlyAfter: cursor)
        let pageReferences = Array(remaining.prefix(pageSize))
        let nextCursor: String?
        if remaining.count > pageReferences.count, let last = pageReferences.last {
            nextCursor = try? ChatArtifactGalleryCursor(
                generation: generation,
                seq: last.lastReferencedSeq,
                path: last.path
            ).token()
        } else {
            nextCursor = nil
        }

        let includeCompleteSections = cursor == nil && !isSearch
        let created = includeCompleteSections
            ? statItems(ordering.sorted(eligibleItems.filter { $0.provenance == .created }))
            : []
        let attached = includeCompleteSections
            ? statItems(ordering.sorted(eligibleItems.filter { $0.provenance == .attached }))
            : []
        return ChatArtifactGalleryPage(
            sessionID: sessionID,
            created: created,
            attached: attached,
            referenced: statItems(pageReferences),
            referencedTotal: candidates.count,
            nextCursor: nextCursor,
            generation: generation
        )
    }

    private func eligibleItems(
        _ items: [ChatArtifactIndexedReference],
        includeDirectories: Bool
    ) -> [ChatArtifactIndexedReference] {
        guard !includeDirectories else { return items }
        let reader = ArtifactByteReader()
        return items.filter { reference in
            (try? reader.stat(path: reference.path).isDirectory) != true
        }
    }

    private func statItems(
        _ references: [ChatArtifactIndexedReference]
    ) -> [ChatArtifactGalleryItem] {
        let reader = ArtifactByteReader()
        return references.map { reference in
            do {
                let stat = try reader.stat(path: reference.path)
                let listing = stat.isDirectory ? try? reader.list(path: reference.path) : nil
                return ChatArtifactGalleryItem(
                    path: reference.path,
                    kind: stat.kind,
                    displayName: URL(fileURLWithPath: reference.path).lastPathComponent,
                    size: stat.size,
                    modifiedAt: stat.modifiedAt,
                    exists: stat.exists,
                    childCount: listing?.entries.count,
                    childCountIsCapped: listing?.isTruncated ?? false,
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
