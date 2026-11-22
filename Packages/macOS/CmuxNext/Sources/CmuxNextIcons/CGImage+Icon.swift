public import CoreGraphics

public nonisolated extension CGImage {
    /// A bitmap of `name` from the pack at `size` points (at least
    /// `CGFloat.iconFloor`) and `scale` pixels per point, inked in `tint`,
    /// for layer-backed views that draw bitmaps. Nil when the pack has no
    /// drawing for `name`; the caller draws the catalog's SF Symbol instead.
    static func icon(_ name: IconName, size: CGFloat, scale: CGFloat, tint: CGColor, style: IconStyle = .line) -> CGImage? {
        let side = max(CGFloat.iconFloor, size)
        let drawn = IconCatalog.bundled.style(style, for: name, size: side)
        guard IconPack.bundled.drawing(for: name) != nil,
              case .drawing(let layers) = IconPack.bundled.resolve(name, style: drawn) else { return nil }
        let pixels = Int((side * scale).rounded())
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // `drawIcon` draws y-down.
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: 1, y: -1)
        context.drawIcon(layers, in: CGRect(x: 0, y: 0, width: pixels, height: pixels), grid: IconPack.bundled.grid, ink: tint)
        return context.makeImage()
    }
}
