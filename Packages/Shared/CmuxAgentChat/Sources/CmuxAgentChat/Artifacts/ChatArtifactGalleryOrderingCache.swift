/// Reuses the stable artifact ordering for repeated pages of one index generation.
public actor ChatArtifactGalleryOrderingCache {
    private struct Key: Hashable {
        let indexID: String
        let generation: String
    }

    private struct Entry {
        let items: [ChatArtifactIndexedReference]
        let access: UInt64
    }

    private let maximumEntryCount: Int
    private var entries: [Key: Entry] = [:]
    private var accessCounter: UInt64 = 0

    /// Creates a bounded ordering cache.
    ///
    /// - Parameter maximumEntryCount: Maximum index generations retained.
    public init(maximumEntryCount: Int = 8) {
        self.maximumEntryCount = max(0, maximumEntryCount)
    }

    /// Returns one newest-first ordering, reusing it for the same index generation.
    ///
    /// A new generation for an index invalidates that index's previous ordering.
    ///
    /// - Parameters:
    ///   - items: De-duplicated references from the authoritative index snapshot.
    ///   - indexID: Stable identity of the transcript index.
    ///   - generation: File generation represented by `items`.
    /// - Returns: References in stable gallery order.
    public func ordered(
        _ items: [ChatArtifactIndexedReference],
        indexID: String,
        generation: String
    ) -> [ChatArtifactIndexedReference] {
        let key = Key(indexID: indexID, generation: generation)
        accessCounter &+= 1
        if let cached = entries[key] {
            entries[key] = Entry(items: cached.items, access: accessCounter)
            return cached.items
        }

        entries = entries.filter { $0.key.indexID != indexID }
        let ordered = ChatArtifactGalleryOrdering().sorted(items)
        guard maximumEntryCount > 0 else { return ordered }
        entries[key] = Entry(items: ordered, access: accessCounter)
        evictIfNeeded()
        return ordered
    }

    private func evictIfNeeded() {
        while entries.count > maximumEntryCount,
              let leastRecent = entries.min(by: { $0.value.access < $1.value.access })?.key {
            entries.removeValue(forKey: leastRecent)
        }
    }
}
