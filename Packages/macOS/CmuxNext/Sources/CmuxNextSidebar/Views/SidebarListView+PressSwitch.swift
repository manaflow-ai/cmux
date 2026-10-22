import AppKit

// Lawrence 2026-10-21: "switching workspaces is very slow ... on mousedown, instantly switch". A plain press on a
// workspace row switches on mouse-down (`SidebarPress.switchedOnPress`), as Finder, Mail and the browsers' tab strips
// do. Leo 2026-10-21 (#23977): a press that drags a row must not leave its workspace shown, so the drag's start puts
// back the item and selection shown before the press. The shown workspace's views stay built (the window's warm
// set), so both swaps are one frame each.
extension SidebarListViewComponents {
    /// Puts back what was shown before `press` switched on mouse-down: its drag moves the row and switches nothing.
    func restorePressSwitch(_ press: Press) {
        guard let switched = press.switchedOnPress else { return }
        self.press?.switchedOnPress = nil
        // Something else switched since the press (a key, the CLI, an agent): that switch stays.
        guard model.activeWorkspaceID == switched.id else { return }
        let (oldItem, oldSelection) = (model.selectedItem, model.selection)
        switch switched.previous {
        case let .workspace(previous)? where previous != switched.id && !model.isPlaceholder(previous) && model.workspace(previous) != nil:
            model.click(previous)
            model.selection = switched.previousSelection.contains(previous) ? switched.previousSelection : [previous]
        case let .topItem(item)?:
            model.selection = switched.previousSelection
            model.send(.activateItem(item, opensWorkspace: false))
        default:
            // The press started from the row's own workspace, a group page, or a workspace that is gone: nothing to
            // put back.
            return
        }
        if !patchSelection(from: oldItem, oldSelection: oldSelection) { reload(animated: true) }
    }
}
