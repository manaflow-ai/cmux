public import AppKit
import CmuxNextDesign

/// Settings > Menus' row icons: `cmux-page://cmux.settings/symbol/<name>` answers the SF Symbol
/// `name` as a black template PNG at twice the menu's point size, which the page tints with a CSS
/// mask, so each row shows the icon its right-click menu shows. Drawn when the page asks.
@MainActor
public struct MenuSymbolImages {
    public static let prefix = "symbol"
    /// The same symbols drawn bold: Settings' category sidebar (Lucas 2026-11-11), `symbol-bold/<name>`.
    public static let boldPrefix = "symbol-bold"

    public init() {}

    /// The weight a resource prefix draws at: regular for `symbol`, bold for `symbol-bold`, nil for others.
    public static func weight(prefix: String) -> NSFont.Weight? {
        prefix == Self.prefix ? .regular : prefix == boldPrefix ? .bold : nil
    }

    /// The PNG of `name` at `weight`; nil for a name that is not an SF Symbol name or that macOS lacks.
    public func png(_ name: String, weight: NSFont.Weight = .regular) -> Data? {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == ".") }) else { return nil }
        let pointSize = NSFont.menuFont(ofSize: 0).pointSize * 2
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = NSImage.packOverride(forSymbol: name, pointSize: pointSize)
            ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
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
