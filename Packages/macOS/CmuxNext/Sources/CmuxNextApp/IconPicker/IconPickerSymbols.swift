import AppKit
import CoreText
import CmuxNextDesign
import CmuxNextPages

/// SF Symbols for the icon picker's Symbols tab: each visible cell's image,
/// drawn on request (the page never bundles symbol images; the names come from
/// ``IconPickerSymbolCatalog``). `cmux-page://cmux.icon-picker/__symbol/<name>.png` and
/// `__symbol/hierarchical/<name>.png` are black template images (hierarchical: layers at
/// decreasing opacity); the page tints them with its theme color (CSS mask), so symbols take
/// the Ghostty theme, never the system accent. `__symbol/multicolor/<name>.png` is a finished
/// image in the symbol's own colors that the page shows as it is.
@MainActor
final class IconPickerSymbols: PageDynamicResourceSource {
    nonisolated static let prefix = "__symbol"
    /// Points of the drawn symbol; the page shows it at 24 px (2x for Retina).
    static let pointSize: CGFloat = 48

    /// How a symbol is drawn (the page's prefs.symbolMode).
    nonisolated enum Mode: String, CaseIterable, Sendable {
        /// Black template; the page tints it.
        case monochrome
        /// Black layers at decreasing opacity; the page tints them.
        case hierarchical
        /// The symbol's own colors (symbols without them draw monochrome).
        case multicolor
    }

    /// The view whose theme and appearance the colored modes draw in (the picker page), so
    /// multicolor's neutral layers match the page's light or dark theme.
    weak var appearanceView: NSView?

    /// The page's cache key for the drawn modes: light or dark (multicolor's neutral layers
    /// follow the appearance). The page puts it in the image URL, so a changed appearance never
    /// reuses a cached image.
    static func style(dark: Bool) -> String {
        dark ? "dark" : "light"
    }

    /// The newest Emoji version (times 10) the system emoji font draws, so the picker hides
    /// emoji that would show as empty boxes: one new single code point per version, newest first.
    static func maxEmojiVersion(font: CTFont = CTFontCreateWithName("AppleColorEmoji" as CFString, 16, nil)) -> Int {
        let sentinels: [(Int, UInt32)] = [(180, 0x1FAEB), (170, 0x1FAEA), (160, 0x1FAE9), (150, 0x1FAE8), (140, 0x1FAE0), (130, 0x1F978)]
        for (version, scalar) in sentinels where draws(scalar, font: font) { return version }
        return 120
    }

    private static func draws(_ scalar: UInt32, font: CTFont) -> Bool {
        guard let character = Unicode.Scalar(scalar) else { return false }
        var units = Array(String(Character(character)).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        // A surrogate pair maps to one glyph in the first slot.
        return CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) && glyphs[0] != 0
    }

    /// The symbol and mode a request names (`<name>.png` is monochrome, `<mode>/<name>.png`
    /// another mode), or nil.
    nonisolated static func symbol(for request: PageResourceRequest) -> (name: String, mode: Mode)? {
        guard request.prefix == prefix, let file = request.path.last, file.hasSuffix(".png") else { return nil }
        let mode: Mode
        switch request.path.count {
        case 1: mode = .monochrome
        case 2:
            guard let named = Mode(rawValue: request.path[0]) else { return nil }
            mode = named
        default: return nil
        }
        let name = String(file.dropLast(4)).removingPercentEncoding ?? ""
        return IconValue.isSymbolName(name) ? (name, mode) : nil
    }

    func resource(for request: PageResourceRequest) async -> PageResource? {
        guard let symbol = Self.symbol(for: request) else { return nil }
        let draw = { Self.png(symbol.name, mode: symbol.mode) }
        let data = appearanceView.map { view in view.performWithTheme(draw) } ?? draw()
        return data.map { PageResource(data: $0, mimeType: "image/png") }
    }

    /// The symbol drawn on clear in `mode`, as PNG; nil when the system has no such symbol.
    /// Monochrome and hierarchical are black (templates the page tints).
    static func png(_ name: String, mode: Mode = .monochrome) -> Data? {
        var config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        switch mode {
        case .monochrome: break
        case .hierarchical: config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: .black))
        case .multicolor: config = config.applying(.preferringMulticolor())
        }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return nil
        }
        let side = Int(pointSize * 1.25)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let size = symbol.size
        let scale = min(CGFloat(side) / size.width, CGFloat(side) / size.height)
        let rect = NSRect(x: (CGFloat(side) - size.width * scale) / 2, y: (CGFloat(side) - size.height * scale) / 2,
                          width: size.width * scale, height: size.height * scale)
        symbol.draw(in: rect)
        return bitmap.representation(using: .png, properties: [:])
    }
}
