import AppKit
import CmuxNextDesign

/// The page is transparent: a snapshot saved as JPEG would turn its
/// background white and flash over a dark pane at the next launch.
enum PageImageBackground {
    /// `page` drawn over `color` (opaque), at the snapshot's pixel size.
    @MainActor
    static func fill(_ page: NSImage, _ color: ThemeRGB) -> NSImage {
        var color = color
        color.alpha = 1
        guard let image = page.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return page }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(color.cgColor)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage().map { NSImage(cgImage: $0, size: page.size) } ?? page
    }
}
