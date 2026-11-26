import AppKit

/// A sidebar row's dot glyph (`appearance.agentSignature`) as a bitmap, drawn once per session id, point
/// size and backing scale and kept (one cache, ``SidebarAgentSignatures/images``): the row's view only shows
/// it (no layer of its own per dot, no animation, no timer). The dots are the variant's accent at
/// ``opacity``; `y` counts from the top, as the web running line draws it.
@MainActor
final class SidebarAgentSignatureImage {
    /// The dots' opacity (the shared contract's look).
    static let opacity: CGFloat = 0.85
    /// Past this many images the cache starts over: a constant bound however many agents a sidebar has seen.
    static let limit = 1024

    private struct Key: Hashable {
        var id: String
        var side: CGFloat
        var scale: CGFloat
    }

    private var images: [Key: NSImage] = [:]
    /// Bitmaps drawn so far (tests: each key draws once).
    private(set) var drawCount = 0

    /// The image of `glyph` (session `id`'s) in a `side`-point square at `scale`; nil when the glyph has no
    /// valid accent or the box is empty.
    func image(id: String, glyph: SidebarAgentSignature, side: CGFloat, scale: CGFloat) -> NSImage? {
        let key = Key(id: id, side: side, scale: scale)
        if let image = images[key] { return image }
        guard let image = Self.draw(glyph, side: side, scale: scale) else { return nil }
        drawCount += 1
        if images.count >= Self.limit { images.removeAll(keepingCapacity: true) }
        images[key] = image
        return image
    }

    /// Draws the dots into one bitmap of `side * scale` pixels.
    static func draw(_ glyph: SidebarAgentSignature, side: CGFloat, scale: CGFloat) -> NSImage? {
        let pixels = Int((side * scale).rounded(.up))
        guard pixels > 0, let rgb = glyph.accentRGB, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: opacity)) // colour-allow: the particles wallpaper variant's accent, from acpmux data
        let box = CGFloat(pixels)
        func unit(_ value: Double) -> CGFloat { CGFloat(min(max(value, 0), 1)) }
        for dot in glyph.dots {
            let radius = unit(dot.r) * box
            guard radius > 0 else { continue }
            let center = CGPoint(x: unit(dot.x) * box, y: (1 - unit(dot.y)) * box)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        guard let bitmap = context.makeImage() else { return nil }
        let image = NSImage(cgImage: bitmap, size: NSSize(width: side, height: side))
        image.isTemplate = false
        return image
    }
}
