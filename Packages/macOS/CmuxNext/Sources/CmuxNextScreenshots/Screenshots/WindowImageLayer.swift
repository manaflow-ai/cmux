package import AppKit

/// A page window's clip shape in window coordinates (``WindowImageLayer/page(_:_:holes:clip:)``),
/// held as its path elements: a `CGPath` is not `Sendable`, and the redraw runs off the main actor.
package nonisolated struct WindowImageClip: Sendable {
    enum Element: Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)
        case close
    }

    let elements: [Element]

    /// Nil for no clip (the page shows as a plain rectangle).
    package init?(_ path: CGPath?) {
        guard let path else { return nil }
        var elements: [Element] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint: elements.append(.move(points[0]))
            case .addLineToPoint: elements.append(.line(points[0]))
            case .addQuadCurveToPoint: elements.append(.quad(points[0], points[1]))
            case .addCurveToPoint: elements.append(.curve(points[0], points[1], points[2]))
            case .closeSubpath: elements.append(.close)
            @unknown default: break
            }
        }
        self.elements = elements
    }

    /// The shape scaled by `scaleX` and `scaleY` (window points to image pixels).
    func path(scaleX: CGFloat, scaleY: CGFloat) -> CGPath {
        func scaled(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scaleX, y: point.y * scaleY) }
        let path = CGMutablePath()
        for element in elements {
            switch element {
            case .move(let point): path.move(to: scaled(point))
            case .line(let point): path.addLine(to: scaled(point))
            case .quad(let control, let point): path.addQuadCurve(to: scaled(point), control: scaled(control))
            case .curve(let first, let second, let point):
                path.addCurve(to: scaled(point), control1: scaled(first), control2: scaled(second))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

/// What ``composite(base:window:layers:)`` paints over a window's base image,
/// bottom first: the page images and child-window images the window server
/// leaves out of a window capture (`debug.window_snapshot`,
/// `cmux window|pane|tab screenshot`).
package nonisolated enum WindowImageLayer: Sendable {
    /// A page image filling a rectangle in window coordinates, except
    /// `holes` (window coordinates), where the page window is cut out, and
    /// only inside `clip` (window coordinates) when there is one: the page
    /// window's mask (a pane's rounded clip, or the part of a pane a docked
    /// column leaves uncovered).
    case page(CGImage, NSRect, holes: [NSRect] = [], clip: WindowImageClip? = nil)
    /// A window server image of child windows, the size of the window.
    case window(CGImage)
    /// An opaque ``maskColor`` fill over a rectangle in window coordinates, widened to whole
    /// pixels and one more on each side, so no pixel of what it covers shows at its edge
    /// (an agent's capture of a browser page or chat, `ScreenshotMask`).
    case mask(NSRect)
    /// Docked DevTools Chromium gave no image of (a rectangle in window coordinates): diagonal
    /// stripes, so the image says the area was not captured instead of showing it blank, as if
    /// DevTools drew nothing there.
    case notCaptured(NSRect)

    /// What a mask paints: an opaque mid gray, the same in light and dark windows.
    static var maskColor: CGColor { CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1) }
    /// The two colors of ``notCaptured(_:)``'s stripes, the same in light and dark windows.
    static var notCapturedColors: (CGColor, CGColor) {
        (CGColor(srgbRed: 0.42, green: 0.42, blue: 0.42, alpha: 1), CGColor(srgbRed: 0.62, green: 0.62, blue: 0.62, alpha: 1))
    }

    /// A Chromium page's layers, bottom first: its docked DevTools (Chromium's image of them, or
    /// ``notCaptured(_:)`` stripes without one), then the page's own image in its own area. DevTools
    /// go first: in device mode they take the whole view and the page sits inside them.
    ///
    /// - Parameters:
    ///   - image: Chromium's image of the page, the size of the page's own area.
    ///   - rect: The page's own area in window coordinates (beside docked DevTools, only its part).
    ///   - holes: Where the page window shows the window instead (window coordinates).
    ///   - clip: The page window's shape (window coordinates), for the page's image only; nil for none.
    ///   - devTools: The docked DevTools' area (window coordinates) and Chromium's image of them;
    ///     nil with none docked.
    /// - Returns: The layers to paint.
    package static func chromiumPage(_ image: CGImage, _ rect: NSRect, holes: [NSRect] = [], clip: CGPath? = nil,
                                     devTools: (area: NSRect, image: CGImage?)? = nil) -> [WindowImageLayer] {
        let shape = WindowImageClip(clip)
        var layers: [WindowImageLayer] = []
        if let devTools {
            // Not the page window's clip: it is worked out from the page's own area, so it holds no
            // part of DevTools beside the page and would cut their whole image away.
            layers.append(devTools.image.map { .page($0, devTools.area) } ?? .notCaptured(devTools.area))
        }
        layers.append(.page(image, rect, holes: holes, clip: shape))
        return layers
    }

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
            case .page(let image, let rect, let holes, let clip):
                // Window coordinates and the bitmap both have a bottom-left origin.
                func pixels(_ rect: NSRect) -> CGRect {
                    CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
                }
                let area = pixels(rect)
                guard area.width > 0, area.height > 0 else { continue }
                context.saveGState()
                if let clip {
                    let shape = clip.path(scaleX: scaleX, scaleY: scaleY)
                    guard !shape.boundingBoxOfPath.isEmpty else {
                        context.restoreGState()
                        continue
                    }
                    context.addPath(shape)
                    context.clip()
                }
                if !holes.isEmpty {
                    let holed = CGMutablePath()
                    holed.addRect(area)
                    for hole in holes { holed.addRect(pixels(hole)) }
                    context.addPath(holed)
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
            case .notCaptured(let rect):
                let area = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
                    .intersection(whole)
                guard !area.isNull, area.width > 0, area.height > 0 else { continue }
                context.saveGState()
                context.clip(to: area)
                let (dark, light) = notCapturedColors
                context.setFillColor(light)
                context.fill(area)
                // Stripes at 45 degrees, 12 px wide, one every 24 px along the edge.
                context.setStrokeColor(dark)
                context.setLineWidth(12)
                var x = area.minX - area.height
                while x < area.maxX {
                    context.move(to: CGPoint(x: x, y: area.minY))
                    context.addLine(to: CGPoint(x: x + area.height, y: area.maxY))
                    x += 24
                }
                context.strokePath()
                context.restoreGState()
            }
        }
        return context.makeImage()
    }
}
