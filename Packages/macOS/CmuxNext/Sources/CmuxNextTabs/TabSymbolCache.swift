import AppKit

/// Tinted SF Symbol images, cached per name, tint, and scale: a memory consumer (`tab-symbol-images`,
/// ``TabImageMemo``) the app registers through ``TabIconMemoryConsumers``.
final class TabSymbolCache {
    static let shared = TabSymbolCache()
    let images: TabImageMemo<CGImage>

    /// - Parameter clock: Times how long a drawn symbol stays in use; tests pass their own.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        images = TabImageMemo(name: "tab-symbol-images", capacity: 256, bytes: TabImageMemo<CGImage>.pixelBytes(_:), clock: clock)
    }

    func image(named name: String, tint: NSColor, pointSize: CGFloat, size: CGFloat, scale: CGFloat) -> CGImage? {
        let resolved = tint.usingColorSpace(.sRGB) ?? tint
        let key = "\(name)|\(resolved.redComponent)|\(resolved.greenComponent)|\(resolved.blueComponent)|\(resolved.alphaComponent)|\(pointSize)|\(size)|\(scale)"
        return images.value(for: key) { Self.draw(named: name, tint: resolved, pointSize: pointSize, size: size, scale: scale) }
    }

    /// `name` in `resolved` at `pointSize`, centered in a square of `size` points at `scale`.
    static func draw(named name: String, tint resolved: NSColor, pointSize: CGFloat, size: CGFloat, scale: CGFloat) -> CGImage? {
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
        return context.makeImage()
    }
}
