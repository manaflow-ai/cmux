import AppKit
import QuartzCore

/// Renders tab or chip layers into the drag image the App's drag session shows.
struct TabSnapshotRenderer {
    let metrics: TabStripMetrics
    let scale: CGFloat
    /// The card behind the layers (the window background, resolved in the strip's theme); nil
    /// draws none (a translucent window: the drag ghost's glass is the card).
    let background: CGColor?

    /// Renders `layers` (tab or chip roots in the clip layer) into one image
    /// covering `frame` (clip coordinates), on `background`'s rounded card when there is one.
    func image(of layers: [CALayer], frame: CGRect) -> TabImage? {
        let size = frame.size
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Layers are flipped; CoreGraphics is not.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        if let background {
            context.setFillColor(background)
            let radius = metrics.cornerRadius
            context.addPath(CGPath(roundedRect: metrics.pillFrame(slotWidth: size.width, height: size.height), cornerWidth: radius, cornerHeight: radius,
                                   transform: nil))
            context.fillPath()
        }
        for layer in layers {
            context.saveGState()
            context.translateBy(x: layer.frame.minX - frame.minX, y: layer.frame.minY - frame.minY)
            layer.render(in: context)
            context.restoreGState()
        }
        return context.makeImage().map(TabImage.init)
    }
}
