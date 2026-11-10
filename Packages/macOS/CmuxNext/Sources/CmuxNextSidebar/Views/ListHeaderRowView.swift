import AppKit
import CmuxNextDesign

/// Projects and Recents' header (`SidebarRowKey.listHeader`): "Projects" or "Recents" in the group header's quiet
/// style, as the ChatGPT app's sidebar titles its lists. A label only: no menu, no fold, no drop target.
final class ListHeaderRowView: SidebarRowView {
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)

    required init(key: SidebarRowKey) {
        super.init(key: key)
        addSubview(name)
    }

    func configure(_ header: SidebarListHeader, count: Int) {
        name.setString(header == .projects ? Strings.projects : Strings.recents)
        name.setFont(SidebarStyle.headerFont)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(name.stringValue), \(Strings.groupCount(count))")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let h = ceil(name.intrinsicContentSize.height)
        let x = SidebarStyle.columns(rowWidth: b.width).lead - SidebarStyle.labelCellPadding
        name.frame = NSRect(x: x, y: SidebarStyle.textY(name, centerY: b.midY), width: max(0, b.width - x - Metrics.space2), height: h)
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme { name.setColor(Palette.textSecondary) }
    }
}
