import AppKit
import CmuxNextDesign

/// A list's header (`SidebarRowKey.listHeader`): "Projects" or "Recents", or one list's "Workspaces", in the sidebar's
/// quiet heading style, as the ChatGPT and Codex apps' sidebars title their lists. A label only: no menu, no fold, no
/// drop target.
final class ListHeaderRowView: SidebarRowView {
    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)

    required init(key: SidebarRowKey) {
        super.init(key: key)
        addSubview(name)
    }

    func configure(_ header: SidebarListHeader, count: Int) {
        let title = switch header {
        case .projects: Strings.projects
        case .recents: Strings.recents
        case .workspaces: Strings.workspacesHeading
        }
        name.setString(title)
        name.setFont(SidebarStyle.headerFont)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        // One list's heading names it only: its rows are the list itself, and `count` covers one computer's.
        setAccessibilityLabel(header == .workspaces ? title : "\(title), \(Strings.groupCount(count))")
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
