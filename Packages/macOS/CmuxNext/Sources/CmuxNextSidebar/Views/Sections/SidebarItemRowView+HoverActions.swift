import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A workspace tile's hover controls, as a workspace row draws them (2026-10-25: a pinned workspace showed no more
/// button on hover): the close x (`onClose`) on the trailing column, the more button (`onMore`, the row's menu) left
/// of it, and Unpin (`onUnpin`) left of that while the workspace is pinned.
/// Only a row item that names an open workspace (`SidebarItemInfo.workspace`) shows them, under the pointer or while
/// its menu is open, never in edit mode (its ✕ removes the item instead). A pinned workspace keeps its x (Leo
/// 2026-11-23, ask-b5d3e0efb6: "so what, you cant close a pinned tab? no good reason for these limitations."), so
/// its ⋮ sits where a regular row's does.
extension SidebarItemRowView {
    /// Whether the controls show now.
    var showsHoverActions: Bool {
        info.workspace != nil && (isHovered || showsMenu) && !isEditing && !style.isIconOnly && style != .favorite && style != .chip
    }

    /// Places the controls on hover and keeps the title and the trailing marks clear of them.
    func layoutHoverActions(in b: NSRect) {
        let shown = showsHoverActions
        if shown, hoverMore == nil, onMore != nil {
            let button = OverflowButton.rowControl(label: Strings.workspaceMenu)
            button.onPress = { [weak self] in self?.onMore?() }
            addSubview(button)
            hoverMore = button
        }
        hoverMore?.isHidden = !shown
        if shown, hoverClose == nil, onClose != nil {
            let button = SidebarIconButton.rowClose(label: Strings.closeButton)
            button.onPress = { [weak self] in self?.onClose?() }
            if let workspace = info.workspace { button.setAccessibilityIdentifier("cmux.sidebar.workspace.\(workspace.rawValue).close") }
            addSubview(button)
            hoverClose = button
        }
        let closes = shown && hoverClose != nil
        hoverClose?.isHidden = !closes
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
        let end = SidebarStyle.trailingColumnFrame(rowWidth: b.width - SidebarStyle.horizontalInset, centerY: b.midY, side: control)
        if closes, let hoverClose {
            hoverClose.frame = end
            hoverMore.frame = end.offsetBy(dx: -SidebarStyle.trailingSlotPitch, dy: 0)
        } else {
            hoverMore.frame = end
        }
        var leading = hoverMore.frame.minX
        if unpins, let hoverUnpin {
            hoverUnpin.frame = hoverMore.frame.offsetBy(dx: -SidebarStyle.trailingSlotPitch, dy: 0)
            leading = hoverUnpin.frame.minX
        }
        title.frame.size.width = max(0, min(title.frame.width, leading - Metrics.space2 - title.frame.minX))
    }
}
