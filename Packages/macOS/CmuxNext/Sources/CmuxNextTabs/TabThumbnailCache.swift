import CoreGraphics

/// Hover card thumbnails of recently hovered tabs (R131): a retarget to a
/// tab seen before shows its thumbnail at once. Least recently used goes
/// first, bounded by count and by decoded bytes; closed tabs leave at the
/// next hover and memory pressure empties it.
struct TabThumbnailCache {
    let maxCount: Int
    let maxBytes: Int
    private var entries: [TabID: CGImage] = [:]
    /// Least recently used first.
    private var order: [TabID] = []
    private(set) var bytes = 0

    init(maxCount: Int = 24, maxBytes: Int = 48 << 20) {
        self.maxCount = maxCount
        self.maxBytes = maxBytes
    }

    var count: Int { entries.count }

    /// The image for `tab`, now the most recently used.
    mutating func image(for tab: TabID) -> CGImage? {
        guard let image = entries[tab] else { return nil }
        touch(tab)
        return image
    }

    mutating func insert(_ image: CGImage, for tab: TabID) {
        remove(tab)
        entries[tab] = image
        order.append(tab)
        bytes += Self.size(of: image)
        while let oldest = order.first, entries.count > maxCount || (bytes > maxBytes && entries.count > 1) {
            remove(oldest)
        }
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

    mutating func removeAll() {
        entries.removeAll()
        order.removeAll()
        bytes = 0
    }

    private mutating func touch(_ tab: TabID) {
        order.removeAll { $0 == tab }
        order.append(tab)
    }

    static func size(of image: CGImage) -> Int { image.bytesPerRow * image.height }
}
