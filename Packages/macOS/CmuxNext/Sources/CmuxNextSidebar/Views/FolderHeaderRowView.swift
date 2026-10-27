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

    private struct Content: Hashable {
        var folder: String
        var fontSize: CGFloat
    }

    func configure(folder: String) {
        guard needsConfigure(Content(folder: folder, fontSize: SidebarStyle.headerFont.pointSize)) else { return }
        name.setString(SidebarFolderTitle.title(folder))
        name.setFont(SidebarStyle.headerFont)
        themedToolTip = folder.isEmpty ? nil : folder
        setAccessibilityLabel(name.stringValue)
        // invalidate: the content changed (`needsConfigure` above).
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let h = ceil(name.intrinsicContentSize.height)
        let x = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        name.frame = NSRect(x: x, y: (b.height - h) / 2, width: max(0, b.width - x - Metrics.space2), height: h)
    }

    /// Layer colors only: `layerContentsRedrawPolicy` (.onSetNeedsDisplay, SidebarRowView) runs it on needsDisplay, never on a resize.
    override func updateLayer() {
        performWithTheme { name.setColor(Palette.textSecondary) }
    }
}
