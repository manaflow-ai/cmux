import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A workspace tile's hover controls, as a workspace row draws them (2026-10-25: a pinned workspace showed no more
/// button on hover): the more button (`onMore`, the tile's menu) at the row's trailing end, on the trailing column, and Unpin
/// (`onUnpin`) left of it while the workspace is pinned.
/// Only a row item that names an open workspace (`SidebarItemInfo.workspace`) shows it, under the pointer or while
/// its menu is open, never in edit mode (its ✕ removes the item instead). Every such item is pinned (a Pinned block's
/// workspace, a band item), so it draws no close x on hover: Lawrence msg 19392, "hover on pinned tab should not
/// have close button, should only be able to close in right click". Close Workspace stays in its menu.
extension SidebarItemRowView {
    /// Whether the controls show now.
    var showsHoverActions: Bool {
        info.workspace != nil && (isHovered || showsMenu) && !isEditing && !style.isIconOnly && style != .favorite && style != .chip
    }

    /// Places the controls on hover and keeps the title and the trailing marks clear of them.
    func layoutHoverActions(in b: NSRect) {
        let shown = showsHoverActions
        // Last, shown or not: no two icons share a box (Leo 2026-11-22: "fucking overlapping icons"), whatever the
        // alphas below say.
        defer { clearMarksMeetingIcons(keep: [hoverMore, hoverUnpin], marks: [rowBadge, badge, activity, taskCount], fades: false) }
        if shown, hoverMore == nil, onMore != nil {
            let button = OverflowButton.rowControl(label: Strings.workspaceMenu)
            button.onPress = { [weak self] in self?.onMore?() }
            addSubview(button)
            hoverMore = button
        }
        hoverMore?.isHidden = !shown
        // The more button whose menu is open stays lit after the pointer leaves for the menu (Leo 2026-10-26).
        hoverMore?.showsMenu = shown && showsMenu
        // The hovered controls replace every trailing mark, in every case (Leo 2026-11-22: "in all cases, the
        // hovered buttons should just replace the other ones"): the dot, the spinner, the status mark and the
        // task count all hide while the controls show, and none of them moves (no layout shift).
        if !isEditing {
            rowBadge.alphaValue = shown ? 0 : 1
            badge.alphaValue = shown ? 0 : 1
        }
        activity.alphaValue = shown ? 0 : 1
        taskCount.alphaValue = shown ? 0 : 1
        // Unpin shows beside the more button, read only while the controls show (a tile at rest asks nothing).
        let unpins = shown && hoverMore != nil && onUnpin != nil && isPinned?() == true
        if unpins, hoverUnpin == nil {
            // Unpin is an action, so it draws the struck-through pin, never the filled pinned mark (`applyPin`).
            let button = SidebarIconButton.rowControl(icon: .browserToolbarUnpin, label: Strings.unpinWorkspace)
            button.onPress = { [weak self] in self?.onUnpin?() }
            if let workspace = info.workspace { button.setAccessibilityIdentifier("cmux.sidebar.workspace.\(workspace.rawValue).pin") }
            addSubview(button)
            hoverUnpin = button
        }
        hoverUnpin?.isHidden = !unpins
        guard shown, let hoverMore else { return }
        // The end-most control takes the trailing column, where the dot or spinner it hides sat.
        let control = SidebarStyle.controlSize
        hoverMore.frame = SidebarStyle.trailingColumnFrame(rowWidth: b.width - SidebarStyle.horizontalInset, centerY: b.midY, side: control)
        var leading = hoverMore.frame.minX
        if unpins, let hoverUnpin {
            hoverUnpin.frame = hoverMore.frame.offsetBy(dx: -SidebarStyle.trailingSlotPitch, dy: 0)
            leading = hoverUnpin.frame.minX
        }
        title.frame.size.width = max(0, min(title.frame.width, leading - Metrics.space2 - title.frame.minX))
    }
}
