import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A list's header (`SidebarRowKey.listHeader`): "Projects" or "Recents", or one list's "Workspaces", in the sidebar's
/// quiet heading style. Projects/Workspaces also exposes This Mac's Share action; no menu, fold, or drop target.
final class ListHeaderRowView: SidebarRowView {
    let screenButton = SidebarIconButton(icon: .actionShare, pointSize: { Metrics.smallIconSize - Metrics.space1 }, label: Strings.shareScreen)
    var allowsShare = false { didSet { needsLayout = true } }
    override var interactiveSubviews: [NSView] { [screenButton] }

    private let name = SidebarRowView.label(font: SidebarStyle.headerFont)

    required init(key: SidebarRowKey) {
        super.init(key: key)
        addSubview(name)
        addSubview(screenButton)
        screenButton.isHidden = true
        screenButton.setAccessibilityIdentifier("cmux.sidebar.list.shareScreen")
    }

    func configure(_ header: SidebarListHeader, count: Int, sharesLocalScreen: Bool = false) {
        allowsShare = sharesLocalScreen && header != .recents
        let title = switch header {
        case .projects: Strings.projects
        case .recents: Strings.recents
        case .workspaces: Strings.workspacesHeading
        }
        name.setString(title)
        name.setFont(SidebarStyle.headerFont)
        setAccessibilityElement(true)
        setAccessibilityRole(allowsShare ? .group : .staticText)
        // One list's heading names it only: its rows are the list itself, and `count` covers one computer's.
        setAccessibilityLabel(header == .workspaces ? title : "\(title), \(Strings.groupCount(count))")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let h = ceil(name.intrinsicContentSize.height)
        let x = SidebarStyle.columns(rowWidth: b.width).lead - SidebarStyle.labelCellPadding
        screenButton.isHidden = !allowsShare
        screenButton.frame = SidebarStyle.trailingColumnFrame(rowWidth: b.width, centerY: b.midY, side: SidebarStyle.controlSize, slot: 0)
        let trailing = allowsShare ? screenButton.frame.minX - Metrics.space2 : b.width - Metrics.space2
        name.frame = NSRect(x: x, y: SidebarStyle.textY(name, centerY: b.midY), width: max(0, trailing - x), height: h)
        needsDisplay = true
    }

    override func updateLayer() {
        performWithTheme { name.setColor(Palette.textSecondary) }
    }
}
