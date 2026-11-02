import AppKit

/// Model changes nobody in this window asked for show calmly (calm-sidebar-movement, Lawrence
/// 2026-10-20: "my sidebar is moving too much and it shows me the animation when it moves. It
/// distracts me"; plans/cmux-next/sidebar-calm-movement.md).
///
/// - A change that follows this app's user's own request (`SidebarModel.followsUserIntent`: a
///   click, a drag, a menu, the palette, a shortcut) moves rows on the spring, as before.
/// - Any other change (an agent's status or title, a workspace the CLI made, a group an agent
///   fills, another client) takes its place in one step, with no row sliding, opening or closing.
/// - While the pointer is over the rows, such a change waits: rows never jump under the pointer
///   or under a scroll. It shows, still without motion, when the pointer leaves the list, or with
///   the next reload of any kind.
extension SidebarListView {
    /// Shows a model change (a structural set, or a row whose new content changes its height).
    /// `animates`: whether the change may animate at all (provisional rows swap in place).
    /// Returns false when the change waits for the pointer to leave.
    @discardableResult
    func showModelChange(animates: Bool) -> Bool {
        let byUser = model.followsUserIntent
        if !byUser, holdsModelChangeNow {
            holdsModelChange = true
            return false
        }
        reload(animated: animates && byUser, fromModel: true)
        return true
    }

    /// Shows a change held while the pointer was over the rows, in one step.
    func releaseHeldModelChange() {
        guard holdsModelChange, drag == nil, settling == nil, landing == nil, external == nil else { return }
        reload(animated: false, fromModel: true)
    }

    /// Shows a held change once the pointer is over neither the rows nor this list's shown hover card
    /// (it left the list, or the card it rested on hid).
    func releaseHeldModelChangeIfPointerLeft() {
        guard holdsModelChange, !pointerIsOverList(self), !pointerIsOnShownHoverCard else { return }
        releaseHeldModelChange()
    }

    /// The pointer rests on the hover card of one of this list's rows: the card follows its row, so
    /// rows hold still while it is read.
    var pointerIsOnShownHoverCard: Bool { hoverCard.isVisible && hoverCards.pointerIsOnShownCard }

    /// A change waits now: the pointer is over the rows and no drag, drop or landing runs (those
    /// reload at their end, which shows the change).
    private var holdsModelChangeNow: Bool {
        guard window != nil, drag == nil, settling == nil, landing == nil, external == nil, !displayed.rows.isEmpty else { return false }
        return pointerIsOverList(self) || pointerIsOnShownHoverCard
    }

    /// The window's pointer is inside the list's visible part, with the list on screen in the active app
    /// (a pointer resting over a background app's window is not the user reading this list).
    var pointerIsOverVisibleRows: Bool {
        guard NSApp?.isActive == true, let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
        return visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}
