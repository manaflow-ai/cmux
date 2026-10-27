// memory: consumer via TabHoverCardController (a value type: its owner registers `tab-hover-cards`, whose
// limit scales both bounds here and whose release trims to them).
import CoreGraphics

/// Hover card thumbnails of recently hovered tabs (R131): a retarget to a
/// tab seen before shows its thumbnail at once. Least recently used goes
/// first, bounded by count and by decoded bytes; closed tabs leave at the
/// next hover. The memory limit lowers both bounds (`setLimits`) and frees nothing;
/// the hover card's memory release drops entries over them (`removeOldest`), as does
/// the next insert.
struct TabThumbnailCache {
    /// The bounds at a 100 % memory limit.
    let maxCount: Int
    let maxBytes: Int
    /// The bounds the memory limit allows now: `maxCount` and `maxBytes` until it lowers them.
    private(set) var countLimit: Int
    private(set) var byteLimit: Int
    private var entries: [TabID: CGImage] = [:]
    /// Least recently used first.
    private var order: [TabID] = []
    private(set) var bytes = 0

    init(maxCount: Int = 24, maxBytes: Int = 48 << 20) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        countLimit = maxCount
        byteLimit = maxBytes
    }

    var count: Int { entries.count }

    /// The image for `tab`, now the most recently used.
    mutating func image(for tab: TabID) -> CGImage? {
        guard let image = entries[tab] else { return nil }
        touch(tab)
        return image
    }

    /// Keeps `image` within the current bounds: at a count bound of 0 it keeps nothing.
    mutating func insert(_ image: CGImage, for tab: TabID) {
        remove(tab)
        entries[tab] = image
        order.append(tab)
        bytes += Self.size(of: image)
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
        guard let image = entries.removeValue(forKey: tab) else { return }
        bytes -= Self.size(of: image)
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

    static func size(of image: CGImage) -> Int { image.bytesPerRow * image.height }
}
