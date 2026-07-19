import Foundation

/// Pure stable-ordering, cursor, and search operations for artifact gallery pages.
public struct ChatArtifactGalleryOrdering: Sendable {
    /// Creates the ordering helper.
    public init() {}

    /// Returns the complete Session-tab count without inspecting the filesystem.
    ///
    /// The indexed references are already de-duplicated by normalized path and
    /// provenance, so this matches `created.count + attached.count +
    /// referencedTotal` on the gallery's unfiltered first page. Missing files
    /// remain in the count because no stat or existence filtering is performed.
    ///
    /// - Parameter items: One transcript-derived artifact index snapshot.
    /// - Returns: The number of artifacts shown by the Session tab.
    public func sessionTotal(_ items: [ChatArtifactIndexedReference]) -> Int {
        items.count
    }

    /// Orders newest transcript references first, with path as a deterministic tie-breaker.
    public func sorted(_ items: [ChatArtifactIndexedReference]) -> [ChatArtifactIndexedReference] {
        items.sorted {
            if $0.lastReferencedSeq != $1.lastReferencedSeq {
                return $0.lastReferencedSeq > $1.lastReferencedSeq
            }
            return $0.path < $1.path
        }
    }

    /// Returns items strictly after a cursor's sort key, independent of generation changes.
    public func items(
        _ items: [ChatArtifactIndexedReference],
        strictlyAfter cursor: ChatArtifactGalleryCursor?
    ) -> [ChatArtifactIndexedReference] {
        let ordered = sorted(items)
        guard let cursor else { return ordered }
        return ordered.filter {
            $0.lastReferencedSeq < cursor.seq
                || ($0.lastReferencedSeq == cursor.seq && $0.path > cursor.path)
        }
    }

    /// Filters by basename or full path using a case-insensitive substring match.
    public func search(
        _ items: [ChatArtifactIndexedReference],
        query: String
    ) -> [ChatArtifactIndexedReference] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sorted(items) }
        return sorted(items).filter { item in
            item.path.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || URL(fileURLWithPath: item.path).lastPathComponent.range(
                    of: needle,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
        }
    }
}
