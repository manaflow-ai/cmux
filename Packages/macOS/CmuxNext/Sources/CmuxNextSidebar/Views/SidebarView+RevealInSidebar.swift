import AppKit
import CmuxNextDesign

// Reveal Workspace in Sidebar (Lawrence msg 20167: "we need a cmd shift p command like focus in sidebar/scroll to in
// sidebar which is im in a workspaces and i want to see it in sidebar so i know where it is"). The one path the
// palette, the workspace row's menu and a shortcut run (`sidebar.revealWorkspace`, CmuxNextSidebarActions).
extension SidebarViewComponents {
    /// Shows workspace `id`'s row: the sidebar shown if hidden (the rail's full sidebar opened), the collapsed
    /// sections, groups and nested groups that hold it opened (the Archive too), its row scrolled into view (centred
    /// when it was out of view) and flashed (``SidebarRevealFlash``; at once under Reduce Motion or with animations
    /// off). Keyboard focus stays where it is; Reveal and Focus moves it after this (`focusSidebar`).
    ///
    /// - Parameter id: The workspace to show, usually the window's current one.
    /// - Returns: False, changing nothing, when this sidebar does not list the workspace.
    @discardableResult
    public func revealWorkspace(_ id: WorkspaceID) -> Bool {
        guard model.lists(id) else { return false }
        // Off screen (out of view, in a fold, or the sidebar hidden): the row comes to the middle.
        let centre = model.isHidden || !list.isRowOnScreen(id)
        if model.isHidden { model.toggle() }
        if model.style == .rail, !model.isRailOpen { model.isRailOpen = true }
        model.expandSections(hiding: id)
        let groups = model.collapsedGroups(holding: id)
        if !groups.isEmpty { model.noteUserIntent() }
        // Outermost first, so each group opens into a list that already shows it.
        for group in groups.reversed() { model.send(.toggleCollapse(.group(group))) }
        renderNow()
        layoutSubtreeIfNeeded()
        return list.revealRow(id, centre: centre)
    }
}
