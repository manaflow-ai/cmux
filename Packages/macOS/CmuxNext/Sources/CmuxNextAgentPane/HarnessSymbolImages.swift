import AppKit

/// SF Symbol images for the pages (user 12922): a custom harness whose icon is an SF Symbol shows
/// it on the agent pane and in Settings, which cannot draw symbols themselves. Each symbol is drawn
/// once as a black template PNG, answered as a `data:` URL the page uses as a mask in its own text
/// color (the pages' CSP allows `data:` images only). Cached by name; a name this Mac cannot draw
/// answers nil and the page keeps the harness's monogram.
@MainActor
public final class HarnessSymbolImages {
    /// Points of the drawn symbol; pages show it at up to 32 px (2x for Retina).
    static let pointSize: CGFloat = 32
    private static let limit = 128
    private var cache: [String: String?] = [:]

    public init() {}

    /// The template PNG of SF Symbol `name` as a `data:image/png;base64,` URL, or nil when the name
    /// is not a symbol name or this Mac draws no such symbol.
    /// - Parameter name: An SF Symbol name (`hammer.fill`).
    public func dataURL(_ name: String) -> String? {
        if let known = cache[name] { return known }
        let answer = Self.isSymbolName(name) ? Self.draw(name) : nil
        if cache.count >= Self.limit { cache.removeAll() }
        cache[name] = answer
        return answer
    }

    /// Lowercase words of letters and digits joined by single dots, at most 128 bytes.
    nonisolated static func isSymbolName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128
            && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { word in
                !word.isEmpty && word.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) }
            }
    }

    private static func draw(_ name: String) -> String? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        else { return nil }
        let size = symbol.size
        let pixels = NSSize(width: ceil(size.width * 2), height: ceil(size.height * 2))
        guard pixels.width > 0, pixels.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        symbol.draw(in: rect)
        // A template's alpha is the shape; fill it black so the page's mask reads it.
        NSColor.black.set()
        rect.fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
