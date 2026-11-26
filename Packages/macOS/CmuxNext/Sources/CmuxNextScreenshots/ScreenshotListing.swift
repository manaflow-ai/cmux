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
    /// The Rust listing; a struct copy shares it until one of them changes (``makeUnique()``).
    private var store = Self.newStore()

    /// A listing of these items (sorted here; a later duplicate path wins).
    ///
    /// - Parameter items: items in any order.
    public init(_ items: [FileGridItem] = []) {
        load(items)
    }

    /// The number of items.
    public var count: Int { items.count }

    /// The item at `path`, if listed.
    ///
    /// - Parameter path: the file path.
    public func item(at path: String) -> FileGridItem? { position(of: path).map { items[$0] } }

    /// Swaps every item of `source` for `newItems` (a fresh scan of that folder).
    ///
    /// - Parameters:
    ///   - source: the source id whose items are replaced.
    ///   - newItems: the scan's items; their `sourceID` should be `source`.
    public mutating func replace(source: String, with newItems: [FileGridItem]) {
        load(items.filter { $0.sourceID != source } + newItems)
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
        if self.item(at: item.id) == item { return }
        makeUnique()
        if let old = position(of: item.id) { items.remove(at: old) }
        ScreenshotsFFI.strings([item.id, item.sourceID]) { text in
            cmux_screenshots_listing_upsert(store.pointer, text[0].bytes, text[0].count, ScreenshotsFFI.raw(item.kind), item.size,
                                            item.modified.timeIntervalSince1970, text[1].bytes, text[1].count)
        }
        if let new = position(of: item.id) { items.insert(item, at: new) }
    }

    /// Removes the item at `path` (deleted, renamed away or left the rule).
    ///
    /// - Parameter path: the file path.
    public mutating func remove(path: String) {
        guard let index = position(of: path) else { return }
        makeUnique()
        items.remove(at: index)
        ScreenshotsFFI.bytes(path) { cmux_screenshots_listing_remove(store.pointer, $0, $1) }
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
        var found = [Int](repeating: 0, count: items.count)
        let ids = sources.map { $0.sorted().joined(separator: "\n") }
        let count = ScreenshotsFFI.strings([query, ids ?? ""]) { text in
            found.withUnsafeMutableBufferPointer {
                cmux_screenshots_listing_filter(store.pointer, text[0].bytes, text[0].count, ids == nil ? nil : text[1].bytes,
                                                text[1].count, $0.baseAddress, $0.count)
            }
        }
        return found.prefix(count).map { items[$0] }
    }

    /// The number of items of each source.
    public var countsBySource: [String: Int] {
        var counts: [String: Int] = [:]
        for item in items { counts[item.sourceID, default: 0] += 1 }
        return counts
    }

    private static func newStore() -> RustHandle {
        RustHandle(cmux_screenshots_listing_new()) { cmux_screenshots_listing_free($0) }
    }

    private func position(of path: String) -> Int? {
        let index = ScreenshotsFFI.bytes(path) { cmux_screenshots_listing_position(store.pointer, $0, $1) }
        return index < 0 ? nil : Int(index)
    }

    /// Gives this copy its own Rust listing before it changes.
    private mutating func makeUnique() {
        if !isKnownUniquelyReferenced(&store) { load(items) }
    }

    /// Lists exactly `all` (a later duplicate path wins) in a new Rust listing, which orders them.
    private mutating func load(_ all: [FileGridItem]) {
        store = Self.newStore()
        let byPath = Dictionary(all.map { ($0.id, $0) }) { _, later in later }
        for (source, group) in Dictionary(grouping: byPath.values, by: \.sourceID) {
            ScreenshotsFFI.strings([source] + group.map(\.id)) { text in
                let raw = zip(group, text.dropFirst()).map { item, path in
                    CmuxScreenshotsItem(path: path.bytes, path_len: path.count, kind: ScreenshotsFFI.raw(item.kind),
                                        size: item.size, modified: item.modified.timeIntervalSince1970)
                }
                cmux_screenshots_listing_replace(store.pointer, text[0].bytes, text[0].count, raw, raw.count)
            }
        }
        items = (0..<cmux_screenshots_listing_count(store.pointer)).compactMap { index in
            var length = 0
            let path = cmux_screenshots_listing_path_at(store.pointer, index, &length)
            return path.flatMap { byPath[String(decoding: UnsafeBufferPointer(start: $0, count: length), as: UTF8.self)] }
        }
    }
}
