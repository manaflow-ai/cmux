import AppKit

/// What ``composite(base:window:layers:)`` paints over a window's base image,
/// bottom first: the page images and child-window images the window server
/// leaves out of a window capture (`debug.window_snapshot`,
/// `cmux window|pane|tab screenshot`).
enum WindowImageLayer {
    /// A page image filling a rectangle in window coordinates, except
    /// `holes` (window coordinates), where the page window is cut out.
    case page(CGImage, NSRect, holes: [NSRect] = [])
    /// A window server image of child windows, the size of the window.
    case window(CGImage)
    /// The window's own composite (`full`, its overlays included) painted back where `coverage`
    /// (its overlays alone, the size of the window) covers what was painted below: a popover or
    /// menu over a page image shows as on screen, with the page under it.
    case overlay(CGImage, coverage: CGImage)

    /// `base` (an image of `window`) with `layers` painted over it, bottom first; nil without layers.
    static func composite(base: CGImage, window: NSWindow, layers: [WindowImageLayer]) -> CGImage? {
        let size = window.frame.size
        guard !layers.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let width = base.width
        let height = base.height
        // sRGB, the space the written PNG is tagged with.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scaleX = CGFloat(width) / size.width
        let scaleY = CGFloat(height) / size.height
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(base, in: whole)
        context.interpolationQuality = .high
        for layer in layers {
            switch layer {
            case .page(let image, let rect, let holes):
                // Window coordinates and the bitmap both have a bottom-left origin.
                func pixels(_ rect: NSRect) -> CGRect {
                    CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
                }
                let area = pixels(rect)
                guard area.width > 0, area.height > 0 else { continue }
                context.saveGState()
                if !holes.isEmpty {
                    let clip = CGMutablePath()
                    clip.addRect(area)
                    for hole in holes { clip.addRect(pixels(hole)) }
                    context.addPath(clip)
                    context.clip(using: .evenOdd)
                }
                context.draw(image, in: area)
                context.restoreGState()
            case .window(let image):
                context.draw(image, in: whole)
            case .overlay(let full, let coverage):
                guard let covered = masked(full, by: coverage, width: width, height: height, space: space) else { continue }
                context.draw(covered, in: whole)
            }
        }
        return context.makeImage()
    }

    /// `image` kept only where `mask` has alpha (premultiplied: `image` times the mask's alpha),
    /// both drawn at `width` x `height` pixels.
    static func masked(_ image: CGImage, by mask: CGImage, width: Int, height: Int, space: CGColorSpace) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let whole = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.draw(mask, in: whole)
        context.setBlendMode(.sourceIn)
        context.draw(image, in: whole)
        return context.makeImage()
    }
}
