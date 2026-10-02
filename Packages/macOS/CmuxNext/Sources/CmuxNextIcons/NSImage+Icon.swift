public import AppKit

extension NSImage {
    /// A template image of `name` at `size` points (at least
    /// `IconMetrics.floor`), for AppKit controls and menus.
    public nonisolated static func icon(_ name: IconName, size: CGFloat, style: IconStyle = .line) -> NSImage {
        let side = max(IconMetrics.floor, size)
        let drawn = IconCatalog.bundled.style(style, for: name, size: side)
        let image: NSImage
        switch IconResolver.resolve(name, style: drawn) {
        case .drawing(let layers):
            let grid = IconPack.bundled.grid
            image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                IconRenderer.draw(layers, in: context, rect: rect, grid: grid, ink: CGColor(gray: 0, alpha: 1))
                return true
            }
        case .system(let symbol):
            let configuration = NSImage.SymbolConfiguration(pointSize: side, weight: .regular)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
                ?? NSImage(size: NSSize(width: side, height: side))
        }
        image.isTemplate = true
        return image
    }
}
