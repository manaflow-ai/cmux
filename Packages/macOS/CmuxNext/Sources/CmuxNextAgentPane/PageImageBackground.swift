import AppKit
import CmuxNextDesign

/// What a saved page image (the next launch's first frame, `AgentPaneLaunchImages`) draws where
/// the page itself is clear.
///
/// A page whose background is opaque (an opaque window) is flattened over that color, so its JPEG
/// never turns the clear pixels white and flashes over a dark pane. A page that is transparent
/// (the New Tab page, or any page over a see-through window or a background image) keeps its
/// clear pixels: the window's backdrop, which paints its art from a snapshot in the first frame,
/// shows through the image as it shows through the live page. Flattening it painted the solid
/// theme color over the art until the live page drew.
enum PageImageBackground {
    /// `page` drawn over `color` at the snapshot's pixel size when `color` is opaque; `page`
    /// itself, clear pixels kept, when the page is transparent (`color` with alpha below 1).
    @MainActor
    static func fill(_ page: NSImage, _ color: ThemeRGB) -> NSImage {
        guard color.alpha >= 1 else { return page }
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
