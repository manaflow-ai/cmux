import AppKit
import CmuxNextDesignTokens
import CmuxNextIcons

/// The React scene renderer's SF Symbols: any symbol an app's scene names that the page's icon
/// pack does not draw, drawn the way the native renderer draws it (`NSImage.icon(symbol:)`: the
/// pack icon the catalog has stand for it, else Apple's symbol), as a black template PNG the page
/// uses as a mask in its own color (``AppsPanelsPageProvider/symbolPrefix``). A name that is not a
/// symbol name, or that this Mac draws no symbol for, answers nil and the page draws its missing glyph.
@MainActor
final class AppSceneSymbolImages {
    /// Points of the drawn symbol; scenes show symbols at up to 32 px (2x for Retina).
    nonisolated static let pointSize: CGFloat = 32
    private static let limit = 128
    private var cache: [String: Data?] = [:]

    func png(_ name: String) -> Data? {
        if let known = cache[name] { return known }
        let answer = Self.draw(name)
        if cache.count >= Self.limit { cache.removeAll() }
        cache[name] = answer
        return answer
    }

    /// Whether `name` names a symbol this Mac draws: a symbol the pack stands for, or Apple's.
    nonisolated static func draws(_ name: String) -> Bool {
        IconValue.isSymbolName(name)
            && (IconCatalog.bundled.name(forSymbol: name) != nil || NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
    }

    nonisolated static func draw(_ name: String) -> Data? {
        guard draws(name) else { return nil }
        let image = NSImage.icon(symbol: name, size: pointSize)
        let size = image.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)), pixelsHigh: Int(ceil(size.height * 2)),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        image.draw(in: rect)
        // A template's alpha is the shape; fill it black so the page's mask reads it.
        NSColor.black.set()
        rect.fill(using: .sourceIn)
        return rep.representation(using: .png, properties: [:])
    }
}
