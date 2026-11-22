import AppKit

/// Tinted SF Symbol images, cached per name, tint, and scale.
final class TabSymbolCache {
    static let shared = TabSymbolCache()
    private var cache: [String: CGImage] = [:]

    func image(named name: String, tint: NSColor, pointSize: CGFloat, size: CGFloat, scale: CGFloat) -> CGImage? {
        let resolved = tint.usingColorSpace(.sRGB) ?? tint
        let key = "\(name)|\(resolved.redComponent)|\(resolved.greenComponent)|\(resolved.blueComponent)|\(resolved.alphaComponent)|\(pointSize)|\(size)|\(scale)"
        if let cached = cache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [resolved]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        let pixels = Int((size * scale).rounded())
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let symbolSize = symbol.size
        let ratio = min(size / symbolSize.width, size / symbolSize.height, 1)
        let drawSize = CGSize(width: symbolSize.width * ratio, height: symbolSize.height * ratio)
        symbol.draw(in: CGRect(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()
        if cache.count > 256 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
