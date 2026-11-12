import AppKit
import CmuxNextDesign

/// What a left press on a workspace row does at the press, before any release.
enum SidebarWorkspacePress: Equatable {
    /// Nothing: a row still connecting or being created, or a control-press (a right-click: its menu).
    case nothing
    /// The second press of a double-click: the row's name is edited in place.
    case renames
    /// A Shift- or Command-press: the selection changes; the shown workspace stays.
    case selects
    /// A press on one row of a multi-selection: the selection is kept for a drag; the release clicks the row.
    case holdsSelection
    /// The multi-view prototype (`sidebar.sideBySide`): the release on the row shows it.
    case showsOnRelease
    /// A plain press: the row's workspace shows at once.
    case shows
}

// A workspace row's press: one reading for the list's `mouseDown` and for the window's press router.
extension SidebarListViewComponents: KeyNeutralPressTarget {
    /// What a left press with `flags` and click count `clicks` on workspace `id`'s row does. `mouseDown` acts on this
    /// and the window's press router asks it first (`keepsKey(for:on:)`), so the two never read one press differently.
    func workspacePress(_ id: WorkspaceID, flags: NSEvent.ModifierFlags, clicks: Int) -> SidebarWorkspacePress {
        if model.isPlaceholder(id) || flags.contains(.control) { return .nothing }
        if clicks == 2, flags.isEmpty { return .renames }
        if flags.contains(.shift) || flags.contains(.command) { return .selects }
        if model.selection.contains(id), model.selection.count > 1 { return .holdsSelection }
        return SidebarTunables.multiViewOn ? .showsOnRelease : .shows
    }

    /// Whether `press` on the row `key` shows, at the press, a workspace the window does not show now.
    func showsAnotherWorkspace(_ press: NSEvent, on key: SidebarRowKey?) -> Bool {
        guard press.type == .leftMouseDown, case let .workspace(id)? = key else { return false }
        let flags = press.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return workspacePress(id, flags: flags, clicks: press.clickCount) == .shows && model.clickShowsAnotherWorkspace(id)
    }

    /// A row press that shows another workspace moves no key: the switch gives the keyboard to that workspace's
    /// content in its own turn, as the workspace keys do. Before, the window was made key for the press and the list
    /// took the keyboard, only for the switch to hand both on: with a Chromium page key that was two changes of the key
    /// window and their layout and draw in the frame of the switch: the click's frame was 14.8 to 18.2 ms behind the
    /// key's at p50 (SPACE SWITCH 4, hold l1, 2 rounds). Chrome's tab strip is in the page's own window, which stays
    /// key through a tab click.
    ///
    /// Every other press takes the window's usual path, as before: one on the shown workspace's row (the list takes the
    /// keyboard), a control-, Shift- or Command-press, a double-click's second press (the rename needs the key), a press
    /// on a row of a multi-selection, a press on a row's button (`hit` is the button), a group header, an item row.
    func keepsKey(for press: NSEvent, on hit: NSView) -> Bool {
        guard hit === self else { return false }
        return showsAnotherWorkspace(press, on: clickHit(at: convert(press.locationInWindow, from: nil))?.key)
    }
}
