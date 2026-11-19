import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A sub-session under its workspace row (`SidebarRowKey.subSession`, `sidebar.nestedSessions`): a Claude Code
/// subagent or a Codex spawned thread, drawn as one line in the row's title style, moved in one indent per level,
/// with its own status mark and, on a sub-session that started others, the tree's chevron. The row is the height
/// of a one-line workspace row (`SidebarLayout.appendNested`). A click selects its workspace; the chevron folds or
/// opens what it started without selecting anything.
final class SubSessionRowView: SidebarRowView {
    private let name = SidebarRowView.label(font: SidebarStyle.titleFont)
    private let line = NSView()
    let activity: StatusIndicatorView = { let view = StatusIndicatorView(); view.usesStatusColors = true; return view }()
    private(set) lazy var chevron: SidebarIconButton = {
        let button = SidebarIconButton(icon: .disclosureExpanded, pointSize: { Metrics.smallIconSize - Metrics.space2 },
                                       label: Strings.collapseSessions)
        button.onPress = { [weak self] in _ = self?.onToggle?() }
        return button
    }()
    private var depth = 1
    private(set) var fold: SidebarTreeFold?
    var onToggle: (() -> Bool)?
    override var interactiveSubviews: [NSView] { fold == nil ? [] : [chevron] }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        line.wantsLayer = true
        addSubview(line)
        addSubview(name)
        addSubview(activity)
        addSubview(chevron)
        chevron.isHidden = true
    }

    func configure(_ row: SidebarRow, session: SidebarSubSession?) {
        let content = row.content ?? WorkspaceRowContent()
        depth = max(1, content.treeDepth)
        fold = content.treeFold
        let title = session?.title ?? ""
        name.setString(title)
        name.setFont(SidebarStyle.titleFont)
        activity.configure(content.activity)
        chevron.isHidden = fold == nil
        chevron.icon = fold == .collapsed ? .disclosureCollapsed : .disclosureExpanded
        chevron.label = fold == .collapsed ? Strings.expandSessions : Strings.collapseSessions
        setAccessibilityElement(true)
        setAccessibilityRole(fold == nil ? .button : .disclosureTriangle)
        setAccessibilityLabel([title, session?.kind].compactMap { $0 }.joined(separator: ", "))
        if fold != nil { setAccessibilityExpanded(fold == .expanded) }
        needsLayout = true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let fold else { return super.accessibilityCustomActions() }
        let action = NSAccessibilityCustomAction(name: fold == .collapsed ? Strings.expandSessions : Strings.collapseSessions) { [weak self] in
            self?.onToggle?() ?? false
        }
        return (super.accessibilityCustomActions() ?? []) + [action]
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        onToggle = nil
        fold = nil
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let columns = SidebarStyle.columns(rowWidth: b.width)
        let indent = CGFloat(depth) * SidebarStyle.treeIndent
        let lead = columns.text(hasLeadingMark: false) - SidebarStyle.labelCellPadding + indent
        let width = max(1, Metrics.lineWidth(1)), reach = Metrics.space1
        line.frame = NSRect(x: lead - indent + Metrics.space2 + CGFloat(depth - 1) * SidebarStyle.treeIndent, y: -reach,
                            width: width, height: b.height + 2 * reach)
        var trailing = columns.textEnd(trailingMarks: 0)
        let glyph = CGSize(width: SidebarStyle.statusGlyphSize, height: SidebarStyle.statusGlyphSize)
        activity.frame = columns.trailingFrame(before: b.width, centerY: b.midY, size: glyph)
        trailing = min(trailing, columns.trailingEdge(before: activity.frame))
        if fold != nil {
            let side = SidebarStyle.controlSize
            chevron.frame = columns.trailingFrame(before: trailing, centerY: b.midY, size: CGSize(width: side, height: side))
            trailing = columns.trailingEdge(before: chevron.frame)
        }
        let h = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: lead, y: SidebarStyle.textY(name, centerY: b.midY), width: max(0, trailing - lead), height: h)
        needsDisplay = true
    }

    override func updateLayer() {
        super.updateLayer()
        performWithTheme {
            name.setColor(isSelected ? Palette.textPrimary : Palette.textSecondary)
            line.layer?.backgroundColor = Palette.separator.cgColor
        }
    }
}
