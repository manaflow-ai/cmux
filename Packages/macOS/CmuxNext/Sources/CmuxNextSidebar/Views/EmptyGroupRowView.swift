import AppKit
import CmuxNextDesign

/// The quiet row under an open group with no members (`SidebarRowKey.emptyGroup`, user 9757): dimmed
/// "No workspaces · drag one here" where a member's title would start. A drop over it goes into the
/// group; a hover offers New Workspace and a click makes one in the group (the header's + path).
/// One label, no observers: the text changes only when the hover or the offer does.
final class EmptyGroupRowView: SidebarRowView {
    private let label = SidebarRowView.label(font: SidebarStyle.subtitleFont)
    /// A click makes a workspace in the group (`SidebarListView.wire` sets it with the action).
    var onAdd: (() -> Void)? { didSet { if (onAdd == nil) != (oldValue == nil) { updateText() } } }
    private var groupName = ""

    required init(key: SidebarRowKey) {
        super.init(key: key)
        label.alignment = .natural
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    func configure(groupName: String) {
        guard needsConfigure(groupName) else { return }
        self.groupName = groupName
        label.setFont(SidebarStyle.subtitleFont)
        updateText()
    }

    /// Whether the hover shows the add offer now.
    private var offersAdd: Bool { isHovered && onAdd != nil }

    private func updateText() {
        label.setString(offersAdd ? Strings.newWorkspace : Strings.groupEmpty)
        setAccessibilityLabel("\(groupName), \(Strings.groupEmpty)")
        setAccessibilityHelp(onAdd == nil ? nil : Strings.newWorkspace)
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
        let x = SidebarStyle.titleLeading - SidebarStyle.labelCellPadding
        label.frame = NSRect(x: x, y: (b.height - h) / 2, width: max(0, b.width - x - Metrics.space2), height: h)
    }

    override func updateLayer() {
        performWithTheme {
            label.setColor(offersAdd ? Palette.textSecondary : Palette.textTertiary)
            paintFill(offersAdd ? Palette.hoverFill : nil)
        }
    }
}
