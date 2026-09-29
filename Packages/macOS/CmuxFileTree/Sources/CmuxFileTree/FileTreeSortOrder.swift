/// How the tree orders siblings, like Finder's View Options.
public struct FileTreeSortOrder: Sendable, Hashable, Codable {
    /// The attribute siblings are ordered by.
    public enum Key: String, Sendable, Hashable, Codable, CaseIterable {
        /// Finder-like natural name order.
        case name
        /// File extension, then name.
        case kind
        /// Modification time, then name.
        case dateModified
        /// File size (directories count as zero), then name.
        case size
    }

    /// The primary attribute.
    public var key: Key
    /// Whether the primary attribute ascends. Name ties always ascend.
    public var ascending: Bool
    /// Whether directories stay above files regardless of the key.
    public var foldersFirst: Bool

    /// Creates a sort order.
    /// - Parameters:
    ///   - key: The primary attribute; name by default.
    ///   - ascending: Whether it ascends; true by default.
    ///   - foldersFirst: Whether directories stay on top; true by default, as
    ///     every editor file tree does.
    public init(key: Key = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.key = key
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    /// The default order: folders first, then names ascending.
    public static let standard = FileTreeSortOrder()

    /// Returns `entries` in this order.
    ///
    /// Sort keys are computed once per entry, so the cost is one pass of key
    /// building plus an `O(n log n)` byte-comparison sort.
    /// - Parameter entries: Entries in any order.
    /// - Returns: The sorted entries.
    public func sorted(_ entries: [FileTreeEntry]) -> [FileTreeEntry] {
        guard entries.count > 1 else { return entries }
        let keys = entries.map { FileTreeNameCollationKey($0.name) }
        let extensions: [String] = key == .kind ? entries.map(\.pathExtension) : []
        var indices = Array(entries.indices)
        indices.sort { lhs, rhs in
            compare(lhs, rhs, entries: entries, keys: keys, extensions: extensions) < 0
        }
        return indices.map { entries[$0] }
    }

    private func compare(
        _ lhs: Int,
        _ rhs: Int,
        entries: [FileTreeEntry],
        keys: [FileTreeNameCollationKey],
        extensions: [String]
    ) -> Int {
        let a = entries[lhs]
        let b = entries[rhs]
        if foldersFirst, a.isDirectory != b.isDirectory {
            return a.isDirectory ? -1 : 1
        }
        let nameOrder = keys[lhs].compare(keys[rhs])
        var primary = 0
        switch key {
        case .name:
            primary = nameOrder
        case .kind:
            primary = extensions[lhs] == extensions[rhs] ? 0 : (extensions[lhs] < extensions[rhs] ? -1 : 1)
        case .dateModified:
            let x = a.modificationTime ?? 0
            let y = b.modificationTime ?? 0
            primary = x == y ? 0 : (x < y ? -1 : 1)
        case .size:
            let x = a.isDirectory ? 0 : (a.size ?? 0)
            let y = b.isDirectory ? 0 : (b.size ?? 0)
            primary = x == y ? 0 : (x < y ? -1 : 1)
        }
        if primary != 0 { return ascending ? primary : -primary }
        if key == .name { return 0 }
        return nameOrder
    }
}
