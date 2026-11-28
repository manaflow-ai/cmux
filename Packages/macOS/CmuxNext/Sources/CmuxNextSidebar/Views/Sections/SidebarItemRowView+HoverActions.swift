import AppKit
import CmuxNextDesign
import CmuxNextIcons

/// A workspace tile's hover controls, the ones a workspace row draws, in the same places (Leo 2026-11-23, ask
/// c-b5d3e0efb6: a pinned chat lost its close, its ⋮ moved and its unpin was not where the pin was; "no good reason
/// for these limitations"): the close ✕ (`onClose`) on the trailing column, the more button (`onMore`, the
/// workspace's own menu) left of it, and Unpin (`onUnpin`) left of that while the workspace is pinned, where the
/// row's Pin was. Only a row item that names an open workspace (`SidebarItemInfo.workspace`) shows them, under the
/// pointer or while its menu is open, never in edit mode (its ✕ removes the item instead).
extension SidebarItemRowView {
    /// Whether the controls show now.
    var showsHoverActions: Bool {
        info.workspace != nil && (isHovered || showsMenu) && !isEditing && !style.isIconOnly && style != .favorite && style != .chip
    }

    /// Places the controls on hover and keeps the title and the trailing marks clear of them.
    func layoutHoverActions(in b: NSRect) {
        let shown = showsHoverActions
        // Home never closes (the store refuses `home_not_closable`), so its tile has no ✕, as its list row has none.
        let closable = info.workspaceRow?.isClosable ?? true
        if shown, closable, hoverClose == nil, onClose != nil {
            let button = SidebarIconButton.rowClose(label: Strings.closeButton)
            button.onPress = { [weak self] in self?.onClose?() }
            if let workspace = info.workspace { button.setAccessibilityIdentifier("cmux.sidebar.workspace.\(workspace.rawValue).close") }
            addSubview(button)
            hoverClose = button
        }
        let closes = shown && closable && hoverClose != nil
        hoverClose?.isHidden = !closes
        // Last, shown or not: no two icons share a box (Leo 2026-11-22: "fucking overlapping icons"), whatever the
        // alphas below say.
        defer { clearMarksMeetingIcons(keep: [hoverClose, hoverMore, hoverUnpin], marks: [rowBadge, badge, activity], fades: false) }
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
        // hovered buttons should just replace the other ones"): the dot, the spinner and the status mark
        // all hide while the controls show, and none of them moves (no layout shift).
        if !isEditing {
            rowBadge.alphaValue = shown ? 0 : 1
            badge.alphaValue = shown ? 0 : 1
        }
        activity.alphaValue = shown ? 0 : 1
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
        layoutRestingPin(in: b, hovering: shown)
        guard shown, let hoverMore else { return }
        // As a workspace row: the ✕ takes the trailing column, where the dot or spinner it hides sat; the ⋮ one slot
        // in from it, the Unpin one more (the row's Pin slot). A row with no close puts the ⋮ on the column.
        let control = SidebarStyle.controlSize
        let column = SidebarStyle.trailingColumnFrame(rowWidth: b.width - SidebarStyle.horizontalInset, centerY: b.midY, side: control)
        if closes, let hoverClose {
            hoverClose.frame = column
            hoverMore.frame = column.offsetBy(dx: -SidebarStyle.trailingSlotPitch, dy: 0)
        } else {
            hoverMore.frame = column
        }
        var leading = hoverMore.frame.minX
        if unpins, let hoverUnpin {
            hoverUnpin.frame = hoverMore.frame.offsetBy(dx: -SidebarStyle.trailingSlotPitch, dy: 0)
            leading = hoverUnpin.frame.minX
        }
        title.frame.size.width = max(0, min(title.frame.width, leading - Metrics.space2 - title.frame.minX))
    }

    /// The menu the hover ⋮ opens: a workspace's own menu, the one its list row's ⋮ opens (a regular chat's, Unpin in
    /// Pin's place), for a workspace tile; the item's menu for any other item.
    func moreMenuTarget(item id: LayoutItemID) -> SidebarContextTarget {
        info.workspace.map { .workspaces([$0]) } ?? .layoutItem(id)
    }

    /// A pinned workspace's filled pin at rest, in the slot its hover Unpin takes (Lawrence 2026-11-28: "i dont see
    /// pinned icon for pinned workspaces anymore"; Leo: "put it in the same spot as the unpin button"). Trailing, so
    /// the title starts where every row's does; on hover the Unpin replaces it in place, so nothing moves.
    func layoutRestingPin(in b: NSRect, hovering: Bool) {
        let pinned = info.workspace != nil && !style.isIconOnly && style != .favorite && style != .chip && isPinned?() == true
        let shows = pinned && !hovering && !isEditing
        if shows, restingPin.image?.size.width != SidebarStyle.indicatorSize {
            restingPin.image = NSImage.icon(.statePinned, size: SidebarStyle.indicatorSize, style: .solid)
            restingPin.contentTintColor = Palette.textTertiary
        }
        restingPin.isHidden = !shows
        guard shows else { return }
        if restingPin.superview == nil { addSubview(restingPin) }
        let closable = info.workspaceRow?.isClosable ?? true
        let column = SidebarStyle.trailingColumnFrame(rowWidth: b.width - SidebarStyle.horizontalInset, centerY: b.midY,
                                                       side: SidebarStyle.controlSize)
        let slot = column.offsetBy(dx: -SidebarStyle.trailingSlotPitch * (closable ? 2 : 1), dy: 0)
        let side = SidebarStyle.indicatorSize
        restingPin.frame = NSRect(x: slot.midX - side / 2, y: slot.midY - side / 2, width: side, height: side)
        title.frame.size.width = max(0, min(title.frame.width, slot.minX - Metrics.space2 - title.frame.minX))
    }
}
