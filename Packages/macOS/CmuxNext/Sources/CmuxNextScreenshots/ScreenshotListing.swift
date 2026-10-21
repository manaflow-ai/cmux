public import CmuxNextFileGrid
import Foundation

/// The files a grid shows, newest first, keyed by path. Pure: scans and
/// watch events go in, the sorted list comes out, so the order rule is
/// tested without a disk.
///
/// Order: newer modification date first, then name (case-insensitive,
/// numeric), then path. A path is in the list at most once.
///
/// Costs: ``replace(source:with:)`` is O(n log n); ``upsert(_:)`` and
/// ``remove(path:)`` find their place by binary search (O(log n) plus the
/// array move), so a live folder with thousands of files takes one new
/// screenshot without a re-sort.
public nonisolated struct ScreenshotListing: Sendable, Equatable {
    /// Every item, newest first.
    public private(set) var items: [FileGridItem] = []
    private var byPath: [String: FileGridItem] = [:]

    /// A listing of these items (sorted here; a later duplicate path wins).
    ///
    /// - Parameter items: items in any order.
    public init(_ items: [FileGridItem] = []) {
        for item in items { byPath[item.id] = item }
        self.items = byPath.values.sorted(by: Self.precedes)
    }

    /// The number of items.
    public var count: Int { items.count }

    /// The item at `path`, if listed.
    ///
    /// - Parameter path: the file path.
    public func item(at path: String) -> FileGridItem? { byPath[path] }

    /// Swaps every item of `source` for `newItems` (a fresh scan of that folder).
    ///
    /// - Parameters:
    ///   - source: the source id whose items are replaced.
    ///   - newItems: the scan's items; their `sourceID` should be `source`.
    public mutating func replace(source: String, with newItems: [FileGridItem]) {
        byPath = byPath.filter { $0.value.sourceID != source }
        for item in newItems { byPath[item.id] = item }
        items = byPath.values.sorted(by: Self.precedes)
    }

    /// Drops every item of `source` (a folder the grid no longer shows).
    ///
    /// - Parameter source: the source id.
    public mutating func removeSource(_ source: String) {
        replace(source: source, with: [])
    }

    /// Adds the item, or moves it to its new place when its path is listed.
    ///
    /// - Parameter item: the item as it is on disk now.
    public mutating func upsert(_ item: FileGridItem) {
        if let old = byPath[item.id] {
            if old == item { return }
            if let index = index(of: old) { items.remove(at: index) }
        }
        byPath[item.id] = item
        items.insert(item, at: insertionIndex(for: item))
    }

    /// Removes the item at `path` (deleted, renamed away or left the rule).
    ///
    /// - Parameter path: the file path.
    public mutating func remove(path: String) {
        guard let old = byPath.removeValue(forKey: path), let index = index(of: old) else { return }
        items.remove(at: index)
    }

    /// The items whose name contains `query` (case- and diacritic-insensitive) and whose source is
    /// in `sources` (nil: every source), still newest first.
    ///
    /// - Parameters:
    ///   - query: text to match in the name; empty matches every item.
    ///   - sources: the source ids to keep, or nil for all.
    public func filtered(query: String, sources: Set<String>?) -> [FileGridItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty, sources == nil { return items }
        return items.filter { item in
            if let sources, !sources.contains(item.sourceID) { return false }
            return needle.isEmpty || item.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The number of items of each source.
    public var countsBySource: [String: Int] {
        var counts: [String: Int] = [:]
        for item in items { counts[item.sourceID, default: 0] += 1 }
        return counts
    }

    /// The grid's order: `lhs` shows before `rhs`.
    ///
    /// - Parameters:
    ///   - lhs: one item.
    ///   - rhs: another item.
    /// - Returns: true when `lhs` is newer, or as new and earlier by name, then path.
    public static func precedes(_ lhs: FileGridItem, _ rhs: FileGridItem) -> Bool {
        if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
        let byName = lhs.name.compare(rhs.name, options: [.caseInsensitive, .numeric])
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.id < rhs.id
    }

    private func insertionIndex(for item: FileGridItem) -> Int {
        var low = 0
        var high = items.count
        while low < high {
            let mid = (low + high) / 2
            if Self.precedes(items[mid], item) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private func index(of item: FileGridItem) -> Int? {
        let index = insertionIndex(for: item)
        return index < items.count && items[index].id == item.id ? index : nil
    }
}
