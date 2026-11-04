import AppKit
import CmuxNextDesign

/// A workspace tile's hover control, as a workspace row draws it (2026-10-25: a pinned workspace showed no more
/// button on hover): the more button (`onMore`, the tile's menu) at the row's trailing end, on the trailing column.
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
        if shown, hoverMore == nil, onMore != nil {
            let button = OverflowButton(label: Strings.workspaceMenu)
            button.onPress = { [weak self] in self?.onMore?() }
            addSubview(button)
            hoverMore = button
        }
        hoverMore?.isHidden = !shown
        // The more button whose menu is open stays lit after the pointer leaves for the menu (Leo 2026-10-26).
        hoverMore?.showsMenu = shown && showsMenu
        // The status mark and the count sit in the controls' place: they hide while the controls show.
        if !isEditing {
            rowBadge.alphaValue = shown ? 0 : 1
            badge.alphaValue = shown ? 0 : 1
        }
        activity.alphaValue = shown ? 0 : 1
        guard shown, let hoverMore else { return }
        // The end-most control takes the trailing column, where the dot or spinner it hides sat.
        let control = SidebarStyle.controlSize
        hoverMore.frame = SidebarStyle.trailingColumnFrame(rowWidth: b.width - SidebarStyle.horizontalInset, centerY: b.midY, side: control)
        title.frame.size.width = max(0, min(title.frame.width, hoverMore.frame.minX - Metrics.space2 - title.frame.minX))
    }
}
