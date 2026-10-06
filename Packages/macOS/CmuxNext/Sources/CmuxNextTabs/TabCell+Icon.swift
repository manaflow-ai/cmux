import AppKit
import CmuxNextDesign
import CmuxNextIcons

extension TabCell {
    /// The tab icon tinted `tint`, at the cell's icon size and scale.
    func iconImage(tint: NSColor) -> CGImage? {
        switch item.icon {
        case .none:
            // A colored tab with no icon shows its color as a dot.
            guard item.tint != nil else { return nil }
            return TabSymbolCache.shared.image(named: "circle.fill", tint: tint, pointSize: Metrics.smallIconSize * 0.6,
                                               size: metrics.iconSize, scale: scale)
        case .image(let image): return image.cgImage
        case .agentMark(let brand):
            return TabAgentMarkCache.shared.image(brand: brand, tint: tint, size: metrics.iconSize, scale: scale)
                ?? TabPackIconCache.shared.image(name: .terminal, tint: tint, size: metrics.iconSize, scale: scale)
        case .icon(let name):
            // The pack fills the icon box; without a drawing, the catalog's SF Symbol at text size.
            return TabPackIconCache.shared.image(name: name, tint: tint, size: metrics.iconSize, scale: scale)
                ?? TabSymbolCache.shared.image(named: IconCatalog.bundled.entry(for: name)?.sf ?? "questionmark.square.dashed",
                                               tint: tint, pointSize: metrics.iconSize, size: metrics.iconSize, scale: scale)
        case .symbol(let name):
            return TabSymbolCache.shared.image(
                named: name,
                tint: tint,
                pointSize: Metrics.smallIconSize,
                size: metrics.iconSize,
                scale: scale
            )
        }
    }
}
