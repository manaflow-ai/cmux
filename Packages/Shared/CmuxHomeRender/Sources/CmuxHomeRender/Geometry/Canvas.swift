import CoreGraphics
import QuartzCore

/// Bitmaps drawn in top-left-origin points at 2x (the coordinate system
/// UIKit's image renderer gives), sRGB, premultiplied BGRA.
enum Canvas {
    static let scale: CGFloat = 2

    static func image(size: CGSize, scale: CGFloat = Canvas.scale, opaque: Bool = false,
                      _ draw: (CGContext) -> Void) -> CGImage? {
        let w = max(1, Int((size.width * scale).rounded(.up))), h = max(1, Int((size.height * scale).rounded(.up)))
        let info = CGBitmapInfo.byteOrder32Little.rawValue
            | (opaque ? CGImageAlphaInfo.noneSkipFirst.rawValue : CGImageAlphaInfo.premultipliedFirst.rawValue)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        draw(ctx)
        return ctx.makeImage()
    }

    /// A snapshot of `layer`'s model tree for `rect` (layer coordinates,
    /// top-left), over `background`. `CALayer.render(in:)` follows the
    /// platform's context convention: UIKit layers expect a flipped context,
    /// AppKit layers a y-up one, so on AppKit the tree renders with its
    /// geometry flipped for the duration of the snapshot.
    @MainActor
    static func snapshot(_ layer: CALayer, rect: CGRect, background: CGColor) -> CGImage? {
        #if os(macOS) && !targetEnvironment(macCatalyst)
        var ancestorsFlipped = false
        var parent = layer.superlayer
        while let p = parent {
            if p.isGeometryFlipped { ancestorsFlipped.toggle() }
            parent = p.superlayer
        }
        let was = layer.isGeometryFlipped
        layer.isGeometryFlipped = !ancestorsFlipped
        defer { layer.isGeometryFlipped = was }
        #endif
        return image(size: rect.size, opaque: true) { ctx in
            ctx.setFillColor(background)
            ctx.fill(CGRect(origin: .zero, size: rect.size))
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            layer.render(in: ctx)
        }
    }

    static func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
    }
}
