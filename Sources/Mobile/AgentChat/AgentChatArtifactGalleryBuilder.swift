import CmuxAgentChat
import Foundation

/// Builds stat-enriched, append-only pages from one transcript index snapshot.
struct AgentChatArtifactGalleryBuilder: Sendable {
    /// Creates a gallery page builder.
    init() {}

    /// Builds one sectioned or flat search page.
    func page(
        sessionID: String,
        items: [ChatArtifactIndexedReference],
        generation: String,
        cursor: ChatArtifactGalleryCursor?,
        pageSize: Int,
        query: String?
    ) -> ChatArtifactGalleryPage {
        let ordering = ChatArtifactGalleryOrdering()
        let normalizedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearch = normalizedQuery?.isEmpty == false
        let candidates: [ChatArtifactIndexedReference]
        if let normalizedQuery, !normalizedQuery.isEmpty {
            candidates = ordering.search(items, query: normalizedQuery)
        } else {
            candidates = ordering.sorted(items.filter { $0.provenance == .referenced })
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
            ? statItems(ordering.sorted(items.filter { $0.provenance == .created }))
            : []
        let attached = includeCompleteSections
            ? statItems(ordering.sorted(items.filter { $0.provenance == .attached }))
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

    private func statItems(
        _ references: [ChatArtifactIndexedReference]
    ) -> [ChatArtifactGalleryItem] {
        let reader = ArtifactByteReader()
        return references.map { reference in
            do {
                let stat = try reader.stat(path: reference.path)
                return ChatArtifactGalleryItem(
                    path: reference.path,
                    kind: stat.kind,
                    displayName: URL(fileURLWithPath: reference.path).lastPathComponent,
                    size: stat.size,
                    modifiedAt: stat.modifiedAt,
                    exists: stat.exists,
                    provenance: reference.provenance
                )
            } catch {
                #if DEBUG
                cmuxDebugLog(
                    "mobile.chat.artifact.gallery unavailable reason=stat-failed path=\(reference.path)"
                )
                #endif
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
