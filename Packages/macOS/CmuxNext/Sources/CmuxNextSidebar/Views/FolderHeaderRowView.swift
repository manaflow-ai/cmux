import AppKit
import CmuxNextDesign

/// Group by Folder's header: the folder's name in the group header's quiet
/// style, the full path as its tooltip. A label only: no menu of its own,
/// no collapse, no drop target.
final class FolderHeaderRowView: SidebarRowView {
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)

    required init(key: SidebarRowKey) {
        super.init(key: key)
        addSubview(name)
    }

    func configure(folder: String) {
        name.stringValue = SidebarFolderTitle.title(folder)
        name.font = SidebarStyle.headerFont
        toolTip = folder.isEmpty ? nil : folder
        setAccessibilityLabel(name.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let h = ceil(name.intrinsicContentSize.height)
        let x = SidebarStyle.titleLeading
        name.frame = NSRect(x: x, y: (b.height - h) / 2, width: max(0, b.width - x - Metrics.space2), height: h)
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme { name.textColor = Palette.textSecondary }
    }
}
