import AppKit
import CoreText
import CmuxNextDesign
import CmuxNextPages

/// SF Symbols for the icon picker's Symbols tab: the names this Mac draws,
/// and each visible cell's image, drawn on request (the page never bundles
/// symbol images). `cmux-page://cmux.icon-picker/__symbol/<name>.png` is a
/// black template image; the page tints it with its theme color (CSS mask).
@MainActor
final class IconPickerSymbols: PageDynamicResourceSource {
    nonisolated static let prefix = "__symbol"
    /// Points of the drawn symbol; the page shows it at 24 px (2x for Retina).
    static let pointSize: CGFloat = 48

    nonisolated static let systemCatalog =
        URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")

    /// The Symbols tab's names, sorted: the bundled snapshot (the symbols the deployment target
    /// draws, scripts/cmux-next/gen-sf-symbol-names.py) plus the names a newer system's catalog
    /// adds. A missing or unreadable system catalog leaves the snapshot, so the tab is never empty.
    /// Both files are read off the main actor.
    @concurrent nonisolated static func names(catalog: URL = systemCatalog) async -> [String] {
        // concurrency-allow: @concurrent, so these file reads never run on the main actor
        var names = Set(snapshot(Bundle.module.url(forResource: "IconPickerSymbols", withExtension: "txt")))
        if let plist = NSDictionary(contentsOf: catalog), let symbols = plist["symbols"] as? [String: Any] {
            names.formUnion(symbols.keys.filter(IconValue.isSymbolName))
        }
        return names.sorted()
    }

    /// The bundled snapshot (Resources/IconPickerSymbols.txt), one name per line.
    private nonisolated static func snapshot(_ url: URL?) -> [String] {
        // concurrency-allow: called only from the @concurrent names(catalog:)
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter(IconValue.isSymbolName)
    }

    /// The newest Emoji version (times 10) the system emoji font draws, so the picker hides
    /// emoji that would show as empty boxes: one new single code point per version, newest first.
    static func maxEmojiVersion(font: CTFont = CTFontCreateWithName("AppleColorEmoji" as CFString, 16, nil)) -> Int {
        let sentinels: [(Int, UInt32)] = [(170, 0x1FAEA), (160, 0x1FAE9), (150, 0x1FAE8), (140, 0x1FAE0), (130, 0x1F978)]
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

    /// The symbol name a request names (`<name>.png`), or nil.
    nonisolated static func name(for request: PageResourceRequest) -> String? {
        guard request.prefix == prefix, request.path.count == 1, let file = request.path.first, file.hasSuffix(".png") else {
            return nil
        }
        let name = String(file.dropLast(4)).removingPercentEncoding ?? ""
        return IconValue.isSymbolName(name) ? name : nil
    }

    func resource(for request: PageResourceRequest) async -> PageResource? {
        guard let name = Self.name(for: request), let data = Self.png(name) else { return nil }
        return PageResource(data: data, mimeType: "image/png")
    }

    /// The symbol drawn black on clear, as PNG; nil when the system has no such symbol.
    static func png(_ name: String) -> Data? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
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
