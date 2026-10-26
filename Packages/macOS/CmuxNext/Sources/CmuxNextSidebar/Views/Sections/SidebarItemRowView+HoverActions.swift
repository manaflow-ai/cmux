import AppKit
import CmuxNextDesign

/// A workspace tile's hover controls, as a workspace row draws them (2026-10-25: a pinned
/// workspace showed no more button and no close x on hover): the close x at the row's trailing end
/// (`onClose`, Close Workspace) and the more button left of it (`onMore`, the tile's menu). Only a
/// row item that names an open workspace (`SidebarItemInfo.workspace`) shows them, under the
/// pointer, never in edit mode (its ✕ removes the item instead).
extension SidebarItemRowView {
    /// Whether the controls show now.
    var showsHoverActions: Bool {
        info.workspace != nil && isHovered && !isEditing && !style.isIconOnly && style != .favorite && style != .chip
    }

    /// Places the controls on hover and keeps the title and the trailing marks clear of them.
    func layoutHoverActions(in b: NSRect) {
        let shown = showsHoverActions
        if shown, hoverClose == nil, onClose != nil {
            let button = SidebarIconButton(icon: .actionClose, pointSize: { Metrics.smallIconSize - Metrics.space2 }, label: Strings.closeButton)
            button.onPress = { [weak self] in self?.onClose?() }
            addSubview(button)
            hoverClose = button
        }
        if shown, hoverMore == nil, onMore != nil {
            let button = OverflowButton(label: Strings.workspaceMenu)
            button.onPress = { [weak self] in self?.onMore?() }
            addSubview(button)
            hoverMore = button
        }
        hoverClose?.isHidden = !shown
        hoverMore?.isHidden = !shown
        // The status mark and the count sit in the controls' place: they hide while the controls show.
        if !isEditing {
            rowBadge.alphaValue = shown ? 0 : 1
            badge.alphaValue = shown ? 0 : 1
        }
        activity.alphaValue = shown ? 0 : 1
        guard shown else { return }
        let control = SidebarStyle.controlSize
        var x = b.width - SidebarStyle.horizontalInset * 2 - control
        if let hoverClose {
            hoverClose.frame = NSRect(x: x, y: (b.height - control) / 2, width: control, height: control)
            x -= control + Metrics.space1
        }
        hoverMore?.frame = NSRect(x: x, y: (b.height - control) / 2, width: control, height: control)
        let start = (hoverMore ?? hoverClose)?.frame.minX ?? b.width
        title.frame.size.width = max(0, min(title.frame.width, start - Metrics.space2 - title.frame.minX))
    }
}
