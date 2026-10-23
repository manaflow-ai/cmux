import AppKit
import CmuxNextDesign
import CmuxNextIcons

extension TabCell {
    /// The tab icon tinted `tint`, at the cell's icon size and scale.
    func iconImage(tint: NSColor) -> CGImage? {
        switch item.icon {
        case .none:
            // A pinned tab is icon-only: without an icon of its own it shows a pin.
            if item.isPinned, item.tint == nil {
                return iconCaches.packIcons.image(name: .statePinned, tint: tint, size: metrics.iconSize, scale: scale)
                    ?? iconCaches.symbols.image(named: "pin.fill", tint: tint, pointSize: Metrics.smallIconSize, size: metrics.iconSize, scale: scale)
            }
            // A colored tab with no icon shows its color as a dot.
            guard item.tint != nil else { return nil }
            return iconCaches.symbols.image(named: "circle.fill", tint: tint, pointSize: Metrics.smallIconSize * 0.6,
                                           size: metrics.iconSize, scale: scale)
        case .image(let image): return image.cgImage
        case .agentMark(let brand):
            return iconCaches.agentMarks.image(brand: brand, tint: tint, size: metrics.iconSize, scale: scale)
                ?? iconCaches.packIcons.image(name: .terminal, tint: tint, size: metrics.iconSize, scale: scale)
        case .icon(let name):
            // The pack fills the icon box; without a drawing, the catalog's SF Symbol at text size.
            return iconCaches.packIcons.image(name: name, tint: tint, size: metrics.iconSize, scale: scale)
                ?? iconCaches.symbols.image(named: IconCatalog.bundled.entry(for: name)?.sf ?? "questionmark.square.dashed",
                                           tint: tint, pointSize: metrics.iconSize, size: metrics.iconSize, scale: scale)
        case .symbol(let name):
            return iconCaches.symbols.image(
                named: name,
                tint: tint,
                pointSize: Metrics.smallIconSize,
                size: metrics.iconSize,
                scale: scale
            )
        }
    }
}
