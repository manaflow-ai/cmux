import AppKit

/// Draws an SVG document into a bitmap with the system's SVG decoder (CoreSVG,
/// through `NSImage`).
///
/// The document must carry concrete paints (``SVGCustomPropertyResolver``):
/// CoreSVG does not resolve CSS custom properties. Safe on any thread: it
/// draws into its own bitmap context and sets the AppKit graphics context only
/// for the current thread.
nonisolated struct SVGRasterizer: Sendable {
    /// The image of `svg` drawn into `size` points at `scale` pixels per point,
    /// or nil when the system cannot decode the document.
    func image(svg: String, size: CGSize, scale: CGFloat) -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0, let decoded = NSImage(data: Data(svg.utf8)), decoded.isValid else { return nil }
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        decoded.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
