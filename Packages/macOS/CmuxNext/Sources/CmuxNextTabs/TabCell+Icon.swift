import AppKit
import CmuxNextDesign
import CmuxNextIcons

extension TabCell {
    /// The tab icon tinted `tint`, at the cell's icon size and scale.
    func iconImage(tint: NSColor) -> CGImage? {
        item.iconImage(tint: tint, size: metrics.iconSize, scale: scale)
    }
}

extension TabItem {
    /// The tab's icon tinted `tint`, `size` points square at `scale`: what its cell draws, and what a folded
    /// pane's bar shows (``CollapsedPaneBarView``).
    func iconImage(tint: NSColor, size: CGFloat, scale: CGFloat) -> CGImage? {
        switch icon {
        case .none:
            // A pinned tab is icon-only: without an icon of its own it shows a pin.
            if isPinned, self.tint == nil {
                return TabPackIconCache.shared.image(name: .statePinned, tint: tint, size: size, scale: scale)
                    ?? TabSymbolCache.shared.image(named: "pin.fill", tint: tint, pointSize: Metrics.smallIconSize, size: size, scale: scale)
            }
            // A colored tab with no icon shows its color as a dot.
            guard self.tint != nil else { return nil }
            return TabSymbolCache.shared.image(named: "circle.fill", tint: tint, pointSize: Metrics.smallIconSize * 0.6,
                                               size: size, scale: scale)
        case .image(let image): return image.cgImage
        case .agentMark(let brand):
            return TabAgentMarkCache.shared.image(brand: brand, tint: tint, size: size, scale: scale)
                ?? TabPackIconCache.shared.image(name: .terminal, tint: tint, size: size, scale: scale)
        case .icon(let name):
            // The pack fills the icon box; without a drawing, the catalog's SF Symbol at text size.
            return TabPackIconCache.shared.image(name: name, tint: tint, size: size, scale: scale)
                ?? TabSymbolCache.shared.image(named: IconCatalog.bundled.entry(for: name)?.sf ?? "questionmark.square.dashed",
                                               tint: tint, pointSize: size, size: size, scale: scale)
        case .symbol(let name):
            return TabSymbolCache.shared.image(
                named: name,
                tint: tint,
                pointSize: Metrics.smallIconSize,
                size: size,
                scale: scale
            )
        }
    }
}
