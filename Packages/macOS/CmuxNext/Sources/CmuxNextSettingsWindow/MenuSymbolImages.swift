public import AppKit

/// Settings > Menus' row icons: `cmux-page://cmux.settings/symbol/<name>` answers the SF Symbol
/// `name` as a black template PNG at twice the menu's point size, which the page tints with a CSS
/// mask, so each row shows the icon its right-click menu shows. Drawn when the page asks.
@MainActor
public struct MenuSymbolImages {
    public static let prefix = "symbol"

    public init() {}

    /// The PNG of `name`; nil for a name that is not an SF Symbol name or that macOS lacks.
    public func png(_ name: String) -> Data? {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == ".") }) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize * 2, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        let size = NSSize(width: ceil(image.size.width), height: ceil(image.size.height))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
