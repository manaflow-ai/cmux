public import AppKit

extension NSImage {
    /// A template image of `name` at `size` points (at least
    /// `CGFloat.iconFloor`), for AppKit controls and menus.
    public nonisolated static func icon(_ name: IconName, size: CGFloat, style: IconStyle = .line) -> NSImage {
        icon(name, size: size, style: style, symbol: nil)
    }

    /// The pack icon that stands for SF Symbol `symbol`, else that symbol, as ``icon(_:size:style:)``
    /// draws it: for symbol names an app or the user supplies.
    public nonisolated static func icon(symbol: String, size: CGFloat, style: IconStyle = .line) -> NSImage {
        let name = IconCatalog.bundled.name(forSymbol: symbol)
        return icon(name ?? IconName(symbol), size: size, style: style, symbol: name == nil ? symbol : nil)
    }

    private nonisolated static func icon(_ name: IconName, size: CGFloat, style: IconStyle, symbol: String?) -> NSImage {
        let side = max(CGFloat.iconFloor, size)
        let drawn = IconCatalog.bundled.style(style, for: name, size: side)
        let image: NSImage
        switch symbol.map(IconResolution.system) ?? IconPack.bundled.resolve(name, style: drawn) {
        case .drawing(let layers):
            let grid = IconPack.bundled.grid
            image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.drawIcon(layers, in: rect, grid: grid, ink: CGColor(gray: 0, alpha: 1))
                return true
            }
        case .system(let symbol):
            // Lay out like a pack icon: a side x side box, with the symbol fitted
            // and centered so wide or tall symbols keep their proportions.
            image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
                guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration),
                    glyph.size.width > 0, glyph.size.height > 0
                else { return true }
                let scale = min(rect.width / glyph.size.width, rect.height / glyph.size.height)
                let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
                let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
                glyph.draw(in: NSRect(origin: origin, size: size))
                return true
            }
        }
        image.isTemplate = true
        return image
    }
}
