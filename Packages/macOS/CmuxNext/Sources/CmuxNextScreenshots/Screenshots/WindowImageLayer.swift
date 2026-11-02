package import AppKit

/// What ``composite(base:window:layers:)`` paints over a window's base image,
/// bottom first: the page images and child-window images the window server
/// leaves out of a window capture (`debug.window_snapshot`,
/// `cmux window|pane|tab screenshot`).
package nonisolated enum WindowImageLayer: Sendable {
    /// A page image filling a rectangle in window coordinates, except
    /// `holes` (window coordinates), where the page window is cut out.
    case page(CGImage, NSRect, holes: [NSRect] = [])
    /// A window server image of child windows, the size of the window.
    case window(CGImage)
    /// An opaque ``maskColor`` fill over a rectangle in window coordinates, widened to whole
    /// pixels and one more on each side, so no pixel of what it covers shows at its edge
    /// (an agent's capture of a browser page or chat, `ScreenshotMask`).
    case mask(NSRect)

    /// What a mask paints: an opaque mid gray, the same in light and dark windows.
    static var maskColor: CGColor { CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1) }

    /// `base` (an image of `window`) with `layers` painted over it, bottom first; nil without layers.
    @MainActor
    package static func composite(base: CGImage, window: NSWindow, layers: [WindowImageLayer]) -> CGImage? {
        composite(base: base, windowSize: window.frame.size, layers: layers)
    }

    /// ``composite(base:windowSize:layers:)`` off the caller's actor: a full-resolution redraw of
    /// the window (an agent's `cmux window screenshot` must not stall the main thread).
    @concurrent
    package static func compositedOffMain(base: CGImage, windowSize: CGSize, layers: [WindowImageLayer]) async -> CGImage? {
        composite(base: base, windowSize: windowSize, layers: layers)
    }

    /// `base` (an image of a window `size` points large) with `layers` painted over it, bottom
    /// first; nil without layers. Any thread.
    package static func composite(base: CGImage, windowSize size: CGSize, layers: [WindowImageLayer]) -> CGImage? {
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
            case .mask(let rect):
                let area = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
                guard area.width > 0, area.height > 0 else { continue }
                let left = (area.minX - 1).rounded(.down), bottom = (area.minY - 1).rounded(.down)
                let pixels = CGRect(x: left, y: bottom, width: (area.maxX + 1).rounded(.up) - left,
                                    height: (area.maxY + 1).rounded(.up) - bottom).intersection(whole)
                guard !pixels.isEmpty else { continue }
                context.saveGState()
                context.setShouldAntialias(false)
                context.setBlendMode(.copy)
                context.setFillColor(maskColor)
                context.fill(pixels)
                context.restoreGState()
            }
        }
        return context.makeImage()
    }
}
