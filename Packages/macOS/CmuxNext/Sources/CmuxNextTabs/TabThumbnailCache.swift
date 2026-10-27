// memory: consumer via TabHoverCardController (a value type: its owner registers `tab-hover-cards`, whose
// limit scales both bounds here and whose release trims to them).
import CmuxNextCompat
import CoreGraphics

/// Hover card thumbnails of recently hovered tabs (R131): a retarget to a
/// tab seen before shows its thumbnail at once. Least recently used goes
/// first, bounded by count and by decoded bytes; closed tabs leave at the
/// next hover. The memory limit lowers both bounds (`setLimits`) and frees nothing;
/// the hover card's memory release drops entries over them (`removeOldest`), as does
/// the next insert.
///
/// The pixels live in ``PurgeableBitmap``s (p07-memory-107): with feature `purgeableImageCaches` on they are
/// volatile purgeable pages except while a card shows them, so the kernel takes them back under pressure; a
/// purged thumbnail is a miss (the card pictures the tab again), never a blank card.
struct TabThumbnailCache {
    /// The bounds at a 100 % memory limit.
    let maxCount: Int
    let maxBytes: Int
    /// The bounds the memory limit allows now: `maxCount` and `maxBytes` until it lowers them.
    private(set) var countLimit: Int
    private(set) var byteLimit: Int
    private let allocator: PurgeableAllocator
    /// The thumbnails' locked bytes (a card shows them, or the pages are resident).
    private let ledger = PurgeableLedger()
    private var entries: [TabID: PurgeableBitmap] = [:]
    /// Least recently used first.
    private var order: [TabID] = []
    private(set) var bytes = 0

    /// - Parameters:
    ///   - maxCount: The most thumbnails it keeps at a 100 % limit.
    ///   - maxBytes: The most decoded bytes it keeps at a 100 % limit.
    ///   - allocator: Makes the thumbnails' pages: purgeable ones with `purgeableImageCaches` on.
    init(maxCount: Int = 24, maxBytes: Int = 48 << 20, allocator: PurgeableAllocator = .resident) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.allocator = allocator
        countLimit = maxCount
        byteLimit = maxBytes
    }

    var count: Int { entries.count }

    /// The thumbnails' bytes, locked (footprint) apart from volatile, and `entries` entries.
    func usage(entries: Int) -> MemoryUsage {
        ledger.usage(totalBytes: bytes, entries: entries)
    }

    /// The image for `tab`, now the most recently used, its pixels locked while the image lives. Nil when
    /// there is none or the kernel purged it: a purged thumbnail leaves the cache.
    mutating func image(for tab: TabID) -> CGImage? {
        guard let bitmap = entries[tab] else { return nil }
        guard let image = bitmap.image() else {
            remove(tab)
            return nil
        }
        touch(tab)
        return image
    }

    /// Keeps a copy of `image`'s pixels within the current bounds: at a count bound of 0 it keeps nothing.
    mutating func insert(_ image: CGImage, for tab: TabID) {
        remove(tab)
        guard countLimit > 0, let bitmap = PurgeableBitmap(image, allocator: allocator) else { return }
        bitmap.attach(to: ledger)
        entries[tab] = bitmap
        order.append(tab)
        bytes += bitmap.byteCount
        trimToLimits()
    }

    /// New bounds, clamped to `0...maxCount` and `0...maxBytes`. It frees nothing: entries
    /// over them go at the next `trimToLimits()` or insert.
    mutating func setLimits(count: Int, bytes: Int) {
        countLimit = min(max(count, 0), maxCount)
        byteLimit = min(max(bytes, 0), maxBytes)
    }

    /// Whether it holds more than the bounds allow. One picture over the byte bound is
    /// allowed while the count bound allows one.
    var isOverLimits: Bool {
        entries.count > countLimit || (bytes > byteLimit && entries.count > 1)
    }

    /// Drops the least recently used entry.
    mutating func removeOldest() {
        if let oldest = order.first { remove(oldest) }
    }

    /// Drops least recently used entries until both bounds hold.
    mutating func trimToLimits() {
        while isOverLimits { removeOldest() }
    }

    mutating func remove(_ tab: TabID) {
        guard let bitmap = entries.removeValue(forKey: tab) else { return }
        bitmap.attach(to: nil)
        bytes -= bitmap.byteCount
        order.removeAll { $0 == tab }
    }

    /// Drops every tab not in `tabs` (closed tabs).
    mutating func keep(only tabs: Set<TabID>) {
        for tab in Array(entries.keys) where !tabs.contains(tab) { remove(tab) }
    }

    private mutating func touch(_ tab: TabID) {
        order.removeAll { $0 == tab }
        order.append(tab)
    }
}
