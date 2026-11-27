import AppKit
import CmuxNextSidebar
import CmuxNextTabs
import CoreText
import ImageIO
public import CmuxNextDaemon

/// Draws each harness's icon (``HarnessIconSpec``) once per harness list for the native surfaces
/// (user 12922): an emoji, a PNG or SVG and a monogram become images, a mark and a symbol stay
/// names. The app owns one and passes ``lookup(for:)``'s value to the tab strip and sidebar
/// mappings; the same list answers the same lookup, so its images keep their identity.
@MainActor
public final class HarnessIconArtwork {
    /// Pixels of a drawn icon's side: the 16 pt icon box at 3x.
    static let pixels = 48
    private var last: (icons: HarnessIcons, lookup: HarnessIconLookup)?

    public init() {}

    /// The drawn icons of `icons`.
    /// - Parameter icons: The icons of the last `_acpmux/harnesses` reply.
    public func lookup(for icons: HarnessIcons) -> HarnessIconLookup {
        if let last, last.icons == icons { return last.lookup }
        var lookup = HarnessIconLookup()
        for (harness, spec) in icons.specs {
            if let art = Self.art(spec) { lookup.art[harness] = (art, spec.isOwn) }
        }
        last = (icons, lookup)
        return lookup
    }

    static func art(_ spec: HarnessIconSpec) -> HarnessIconLookup.Art? {
        switch spec {
        case .brand(let brand, _): return .brand(brand)
        case .glyph: return nil
        case .symbol(let name, let letters, let hue, _):
            // A name this Mac cannot draw (a newer system's) shows the monogram.
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return .symbol(name) }
            return image(monogram(letters, hue: hue))
        case .emoji(let text, _):
            guard case .image(let tabImage)? = TabUserIcon.shared.icon(text) else { return nil }
            return .image(tabImage, SidebarFavicon(tabImage.cgImage))
        case .image(let data, let mime, _): return image(decode(data, mime: mime))
        case .monogram(let letters, let hue, _): return image(monogram(letters, hue: hue))
        }
    }

    private static func image(_ cgImage: CGImage?) -> HarnessIconLookup.Art? {
        cgImage.map { .image(TabImage($0), SidebarFavicon($0)) }
    }

    /// A PNG's or SVG's bytes as an image of ``pixels`` square, its aspect kept.
    static func decode(_ data: Data, mime: String) -> CGImage? {
        if mime == "image/png", let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceThumbnailMaxPixelSize: pixels,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        var rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// `letters` in white on a rounded square of `hue` (the pages' light-surface color, which
    /// reads on both themes).
    static func monogram(_ letters: String, hue: Int) -> CGImage? {
        let side = CGFloat(pixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let fill = NSColor(hue: CGFloat(hue) / 360, saturation: 0.62, brightness: 0.70, alpha: 1)
        context.setFillColor(fill.cgColor)
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: side * 0.28, cornerHeight: side * 0.28, transform: nil))
        context.fillPath()
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, side * (letters.count > 1 ? 0.46 : 0.58), nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, side * 0.5, nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.cgColor]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: letters, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: (side - bounds.width) / 2 - bounds.minX, y: (side - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
