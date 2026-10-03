import CoreGraphics

/// Row bitmaps by content, with a bounded cache. The key is the row's kind
/// and height (never its key or the viewport width), so equal content
/// shares one bitmap and a resize redraws only rows whose wrap changed.
@MainActor
final class RowBitmaps {
    private struct Key: Hashable {
        var kind: RowSpec.Kind
        var height: CGFloat
        var palette: Int
    }

    private var cache: [Key: CGImage] = [:]
    private var order: [Key] = []
    private var bytes = 0
    static let capacity = 500
    static let maxBytes = 96 << 20
    /// Bitmaps drawn (tests read it to prove a reflow redraws only changed rows).
    private(set) var renderCount = 0
    /// Bumped when the palette changes; old bitmaps stop matching.
    private(set) var paletteGeneration = 0
    private(set) var palette: HomePalette

    init(palette: HomePalette) { self.palette = palette }

    func setPalette(_ new: HomePalette) {
        guard new != palette else { return }
        palette = new
        paletteGeneration += 1
        cache.removeAll()
        order.removeAll()
        bytes = 0
    }

    /// The row's bitmap, drawn now on a miss.
    func image(for spec: RowSpec, size: CGSize) -> CGImage? {
        let key = Key(kind: spec.kind, height: spec.height, palette: paletteGeneration)
        if let hit = cache[key] { return hit }
        renderCount += 1
        let palette = self.palette
        guard let image = Canvas.image(size: size, { RowArt.draw(spec, palette: palette, $0) }) else { return nil }
        store(key, image)
        return image
    }

    private func store(_ key: Key, _ image: CGImage) {
        cache[key] = image
        order.append(key)
        bytes += image.bytesPerRow * image.height
        guard order.count > Self.capacity + 100 || bytes > Self.maxBytes else { return }
        var n = 0
        while n < order.count - 1, order.count - n > Self.capacity || bytes > Self.maxBytes * 3 / 4 {
            if let old = cache.removeValue(forKey: order[n]) { bytes -= old.bytesPerRow * old.height }
            n += 1
        }
        order.removeFirst(n)
    }
}
