import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// The quiet row under an open group with no members (`SidebarRowKey.emptyGroup`, user 9757): dimmed
/// "No workspaces · drag one here" where a member's title would start. A drop over it goes into the
/// group; a hover offers New Workspace and a click makes one in the group (the header's + path).
/// A + on the trailing column shows at rest (user 17912, "empty workspace needs plus button"), so the
/// way to fill the group reads without a hover. One label and one button, no observers: the text
/// changes only when the hover or the offer does.
final class EmptyGroupRowView: SidebarRowView {
    private let label = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// The +: New Workspace in Group, as a click on the row and the header's + run.
    let addButton = SidebarIconButton(icon: .actionAdd, pointSize: { Metrics.smallIconSize - Metrics.space1 },
                                      label: Strings.newWorkspace)
    /// A click makes a workspace in the group (`SidebarListView.wire` sets it with the action).
    var onAdd: (() -> Void)? { didSet { if (onAdd == nil) != (oldValue == nil) { updateText() } } }
    private var groupName = ""

    override var interactiveSubviews: [NSView] { [addButton] }

    required init(key: SidebarRowKey) {
        super.init(key: key)
        label.alignment = .natural
        addSubview(label)
        addSubview(addButton)
        addButton.onPress = { [weak self] in self?.onAdd?() }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    func configure(groupID: GroupID, groupName: String) {
        guard needsConfigure([groupID.rawValue, groupName]) else { return }
        self.groupName = groupName
        addButton.setAccessibilityIdentifier("cmux.sidebar.group.\(groupID.rawValue).emptyAdd")
        label.setFont(SidebarStyle.subtitleFont)
        updateText()
    }

    /// Whether the hover shows the add offer now.
    private var offersAdd: Bool { isHovered && onAdd != nil }

    private func updateText() {
        label.setString(offersAdd ? Strings.newWorkspace : Strings.groupEmpty)
        setAccessibilityLabel("\(groupName), \(Strings.groupEmpty)")
        setAccessibilityHelp(onAdd == nil ? nil : Strings.newWorkspace)
        addButton.isHidden = onAdd == nil
        needsLayout = true
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onAdd else { return false }
        onAdd()
        return true
    }

    override func hoverChanged() {
        super.hoverChanged()
        updateText()
    }

    override func prepareForReuse(key: SidebarRowKey) {
        super.prepareForReuse(key: key)
        onAdd = nil
    }

    override func layout() {
        super.layout()
        let b = layoutBounds
        let h = ceil(label.intrinsicContentSize.height)
        let x = SidebarStyle.columns(rowWidth: b.width).text(hasLeadingMark: false) - SidebarStyle.labelCellPadding
        // The + centers on the trailing column, where the header's chevron above it sits; the label ends left of it.
        let side = SidebarStyle.trailingSlotSide
        addButton.frame = SidebarStyle.trailingColumnFrame(rowWidth: b.width, centerY: b.height / 2, side: side)
        let end = addButton.isHidden ? b.width - Metrics.space2 : addButton.frame.minX - Metrics.space2
        label.frame = NSRect(x: x, y: SidebarStyle.textY(label, centerY: b.midY), width: max(0, end - x), height: h)
    }

    override func updateLayer() {
        performWithTheme {
            label.setColor(offersAdd ? Palette.textSecondary : Palette.textTertiary)
            paintFill(offersAdd ? Palette.hoverFill : nil)
        }
    }
}
