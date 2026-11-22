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

    /// The glyph's bitmaps come from ``IconRasters``: drawn once per drawing, side and scale, and shared by every
    /// image of them (REOPEN-F7: a drawing-handler image per call rasterized the glyph once per view).
    private nonisolated static func icon(_ name: IconName, size: CGFloat, style: IconStyle, symbol: String?) -> NSImage {
        let side = max(CGFloat.iconFloor, size)
        let glyph = IconRasters.Glyph(name: name.rawValue, style: style, symbol: symbol)
        return rasterIcon(glyph, side: side) {
            let drawn = IconCatalog.bundled.style(style, for: name, size: side)
            return symbol.map(IconResolution.system) ?? IconPack.bundled.resolve(name, style: drawn)
        }
    }
}
