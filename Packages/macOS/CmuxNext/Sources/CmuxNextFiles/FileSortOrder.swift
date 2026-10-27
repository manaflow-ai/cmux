import Foundation

/// How a Files listing is ordered: a column and a direction, folders first or not.
public struct FileSortOrder: Sendable, Hashable, Codable {
    /// The column a listing sorts by.
    public enum Field: String, Sendable, Hashable, Codable, CaseIterable {
        /// Finder name order (``FileNameSortKey``).
        case name
        /// Last content change.
        case modified
        /// Creation date.
        case created
        /// Bytes (folders count as 0).
        case size
        /// The kind (folders, then by extension).
        case kind
    }

    /// The column.
    public var field: Field
    /// Smallest first when true.
    public var ascending: Bool
    /// Folders before files whatever the column (Finder's "Keep folders on top").
    public var foldersFirst: Bool

    /// Makes an order. Defaults: by name, ascending, folders mixed in (Finder's default).
    public init(field: Field = .name, ascending: Bool = true, foldersFirst: Bool = false) {
        self.field = field
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }

    /// `entries` in this order; ties fall back to name order, then the raw name.
    ///
    /// The sort compares flat copies of the keys (one byte buffer of name
    /// keys, one array of numbers) by index, so no entry is copied or
    /// retained per comparison: 100 000 items sort in tens of milliseconds.
    public func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        let count = entries.count
        guard count > 1 else { return entries }
        var offsets = [Int](repeating: 0, count: count + 1)
        var total = 0
        for (index, entry) in entries.enumerated() {
            offsets[index] = total
            total += entry.sortKey.bytes.count
        }
        offsets[count] = total
        var names = [UInt8]()
        names.reserveCapacity(total)
        for entry in entries { names.append(contentsOf: entry.sortKey.bytes) }
        let numbers: [Double] = switch field {
        case .name, .kind: []
        case .modified: entries.map { $0.modified.timeIntervalSinceReferenceDate }
        case .created: entries.map { $0.created.timeIntervalSinceReferenceDate }
        case .size: entries.map { Double($0.size) }
        }
        let kinds: [FileNameSortKey] = field == .kind ? entries.map(Self.kindRank) : []
        let folders: [Bool] = foldersFirst ? entries.map(\.kind.isFolderLike) : []
        let ascending = ascending
        let byField = field
        var order = Array(0..<count)
        // SAFETY: `nameBytes` and `offs` are the two arrays' own storage, valid only inside these closures, which
        // let no pointer out (the sort runs inside them). `offs` holds count + 1 ascending offsets that end at
        // names.count, so item i's key is the offs[i + 1] - offs[i] bytes from offs[i], inside `names`; memcmp reads
        // `common` bytes, at most either key's length, from the start of each key. The buffer subscripts are
        // unchecked in release; they stay in bounds because a and b are the order's own indices (a, b < count) and
        // offs.count == count + 1, so offs[a] and offs[a + 1] both exist.
        unsafe names.withUnsafeBufferPointer { nameBytes in
            unsafe offsets.withUnsafeBufferPointer { offs in
                func nameCompare(_ a: Int, _ b: Int) -> Int {
                    // SAFETY: a, b < count and offs.count == count + 1 (the argument above the closures), so both
                    // reads are in bounds and both keys lie inside `names`.
                    let la = unsafe offs[a + 1] - offs[a], lb = unsafe offs[b + 1] - offs[b]
                    let common = min(la, lb)
                    if common > 0, let base = unsafe nameBytes.baseAddress {
                        let r = unsafe memcmp(base + offs[a], base + offs[b], common)
                        if r != 0 { return Int(r) }
                    }
                    return la - lb
                }
                order.sort { a, b in
                    if !folders.isEmpty, folders[a] != folders[b] { return folders[a] }
                    var primary = 0
                    switch byField {
                    case .name: primary = nameCompare(a, b)
                    case .kind: primary = kinds[a].compare(kinds[b])
                    case .modified, .created, .size:
                        primary = numbers[a] < numbers[b] ? -1 : (numbers[a] > numbers[b] ? 1 : 0)
                    }
                    if primary != 0 { return ascending ? primary < 0 : primary > 0 }
                    if byField != .name {
                        let byName = nameCompare(a, b)
                        if byName != 0 { return byName < 0 }
                    }
                    return entries[a].name < entries[b].name
                }
            }
        }
        return order.map { entries[$0] }
    }

    /// True when `a` comes before `b`.
    public func inOrder(_ a: FileEntry, _ b: FileEntry) -> Bool {
        if foldersFirst, a.kind.isFolderLike != b.kind.isFolderLike { return a.kind.isFolderLike }
        let primary: Int
        switch field {
        case .name: primary = a.sortKey.compare(b.sortKey)
        case .modified: primary = a.modified < b.modified ? -1 : (a.modified > b.modified ? 1 : 0)
        case .created: primary = a.created < b.created ? -1 : (a.created > b.created ? 1 : 0)
        case .size: primary = a.size < b.size ? -1 : (a.size > b.size ? 1 : 0)
        case .kind: primary = Self.kindRank(a).compare(Self.kindRank(b))
        }
        if primary != 0 { return ascending ? primary < 0 : primary > 0 }
        let byName = a.sortKey.compare(b.sortKey)
        if byName != 0 { return byName < 0 }
        return a.name < b.name
    }

    private static func kindRank(_ entry: FileEntry) -> FileNameSortKey {
        // Folders first (0), then files by extension (1 + its key); a file with
        // no extension must still come after every folder.
        entry.kind.isFolderLike ? FileNameSortKey(bytes: [0]) : FileNameSortKey(bytes: [1] + FileNameSortKey(entry.pathExtension).bytes)
    }
}
