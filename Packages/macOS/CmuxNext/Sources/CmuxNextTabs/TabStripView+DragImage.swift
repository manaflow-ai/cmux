public import AppKit
import CmuxNextDesign

// The drag ghost's tab image drawn again in the strip's theme now, for a ghost that follows a theme change.
extension TabStripView {
    /// A fresh drag image of tab `id` at `size`, lifted, drawn in this strip's theme now
    /// (`snapshot(of:frame:)`), and whether it was drawn for glass. The ghost of a tab this strip
    /// handed off redraws with it when the theme changes mid-drag (a light/dark switch), so it
    /// never keeps the colors of the moment it was picked up. Nil when the strip no longer knows
    /// the tab.
    public func dragImage(of id: TabID, size: CGSize) -> (image: TabImage?, onGlass: Bool)? {
        guard let item = model.tab(id), size.width > 0, size.height > 0 else { return nil }
        let cell = TabCell(item: item)
        cell.style = model.style
        cell.metrics = metrics
        cell.titleFont = Typography.tabTitle
        cell.themeScope = themeScope
        cell.scale = window?.backingScaleFactor ?? 2
        cell.isWindowMain = true
        cell.isSelected = model.selectedID == id
        cell.isLifted = true
        cell.setFrame(CGRect(origin: .zero, size: size), laysOut: true)
        return snapshot(of: [cell.layer], frame: cell.frame)
    }
}
