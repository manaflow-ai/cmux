import CCmuxScreenshotsFFI
public import CmuxNextFileGrid
import Foundation

/// The files a grid shows, newest first, keyed by path. The order and the filter are Rust's
/// (cmux-screenshots `listing.rs`); this keeps the items it places. Pure: scans and watch events
/// go in, the sorted list comes out, so the order rule is tested without a disk.
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
    private var store = Store()

    /// A listing of these items (sorted here; a later duplicate path wins).
    ///
    /// - Parameter items: items in any order.
    public init(_ items: [FileGridItem] = []) {
        for item in items { byPath[item.id] = item }
        for (source, sourceItems) in Dictionary(grouping: byPath.values, by: \.sourceID) {
            store.replace(source: source, with: sourceItems)
        }
        self.items = store.paths().compactMap { byPath[$0] }
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
        makeUnique()
        byPath = byPath.filter { $0.value.sourceID != source }
        for item in newItems { byPath[item.id] = item }
        store.replace(source: source, with: newItems)
        items = store.paths().compactMap { byPath[$0] }
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
        if byPath[item.id] == item { return }
        makeUnique()
        if let old = store.position(of: item.id) { items.remove(at: old) }
        byPath[item.id] = item
        store.upsert(item)
        if let new = store.position(of: item.id) { items.insert(item, at: new) }
    }

    /// Removes the item at `path` (deleted, renamed away or left the rule).
    ///
    /// - Parameter path: the file path.
    public mutating func remove(path: String) {
        guard byPath.removeValue(forKey: path) != nil else { return }
        makeUnique()
        if let index = store.position(of: path) { items.remove(at: index) }
        store.remove(path: path)
    }

    /// The items whose name contains `query` (case- and diacritic-insensitive) and whose source is
    /// in `sources` (nil: every source), still newest first.
    ///
    /// - Parameters:
    ///   - query: text to match in the name; empty matches every item.
    ///   - sources: the source ids to keep, or nil for all.
    public func filtered(query: String, sources: Set<String>?) -> [FileGridItem] {
        if sources == nil, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return items }
        if sources?.isEmpty == true { return [] }
        return store.filter(query: query, sources: sources).map { items[$0] }
    }

    /// The number of items of each source.
    public var countsBySource: [String: Int] {
        var counts: [String: Int] = [:]
        for item in items { counts[item.sourceID, default: 0] += 1 }
        return counts
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.items == rhs.items }

    /// Gives this copy its own Rust listing before it changes (a struct copy shares the store).
    private mutating func makeUnique() {
        guard !isKnownUniquelyReferenced(&store) else { return }
        let copy = Store()
        for (source, sourceItems) in Dictionary(grouping: byPath.values, by: \.sourceID) {
            copy.replace(source: source, with: sourceItems)
        }
        store = copy
    }

    /// The Rust listing, freed with the last copy that holds it.
    private final class Store: @unchecked Sendable { // changed only through a uniquely held copy
        let listing = cmux_screenshots_listing_new()
        deinit { cmux_screenshots_listing_free(listing) }

        func replace(source: String, with items: [FileGridItem]) {
            let paths = items.flatMap { Array($0.id.utf8) }
            paths.withUnsafeBufferPointer { bytes in
                var offset = 0
                let raw = items.map { item in
                    let count = item.id.utf8.count
                    defer { offset += count }
                    return CmuxScreenshotsItem(path: bytes.baseAddress.map { $0 + offset }, path_len: count,
                                               kind: ScreenshotsFFI.raw(item.kind), size: item.size,
                                               modified: item.modified.timeIntervalSince1970)
                }
                ScreenshotsFFI.bytes(source) { source, sourceCount in
                    raw.withUnsafeBufferPointer { cmux_screenshots_listing_replace(listing, source, sourceCount, $0.baseAddress, $0.count) }
                }
            }
        }

        func upsert(_ item: FileGridItem) {
            ScreenshotsFFI.bytes(item.id) { path, pathCount in
                ScreenshotsFFI.bytes(item.sourceID) { source, sourceCount in
                    cmux_screenshots_listing_upsert(listing, path, pathCount, ScreenshotsFFI.raw(item.kind), item.size,
                                                    item.modified.timeIntervalSince1970, source, sourceCount)
                }
            }
        }

        func remove(path: String) {
            ScreenshotsFFI.bytes(path) { cmux_screenshots_listing_remove(listing, $0, $1) }
        }

        func position(of path: String) -> Int? {
            let index = ScreenshotsFFI.bytes(path) { cmux_screenshots_listing_position(listing, $0, $1) }
            return index < 0 ? nil : Int(index)
        }

        /// Every listed path, newest first.
        func paths() -> [String] {
            (0..<cmux_screenshots_listing_count(listing)).compactMap { index in
                var length = 0
                guard let bytes = cmux_screenshots_listing_path_at(listing, index, &length) else { return nil }
                return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
            }
        }

        func filter(query: String, sources: Set<String>?) -> [Int] {
            var out = [Int](repeating: 0, count: cmux_screenshots_listing_count(listing))
            let found = ScreenshotsFFI.bytes(query) { query, queryCount in
                let run = { (ids: UnsafePointer<UInt8>?, idsCount: Int) in
                    out.withUnsafeMutableBufferPointer { cmux_screenshots_listing_filter(listing, query, queryCount, ids, idsCount, $0.baseAddress, $0.count) }
                }
                return sources.map { ScreenshotsFFI.bytes($0.sorted().joined(separator: "\n"), run) } ?? run(nil, 0)
            }
            return Array(out.prefix(found))
        }
    }
}
