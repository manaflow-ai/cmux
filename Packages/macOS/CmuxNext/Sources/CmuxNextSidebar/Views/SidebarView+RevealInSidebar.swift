import AppKit
import CmuxNextDesign

// Reveal Workspace in Sidebar (Lawrence msg 20167: "we need a cmd shift p command like focus in sidebar/scroll to in
// sidebar which is im in a workspaces and i want to see it in sidebar so i know where it is"). The one path the
// palette, the workspace row's menu and a shortcut run (`sidebar.revealWorkspace`, CmuxNextSidebarActions).
extension SidebarViewComponents {
    /// Shows workspace `id`'s row. Not done yet: it only answers whether the sidebar lists the workspace.
    ///
    /// - Parameter id: The workspace to show, usually the window's current one.
    /// - Returns: False when this sidebar does not list the workspace.
    @discardableResult
    public func revealWorkspace(_ id: WorkspaceID) -> Bool {
        model.lists(id)
    }
}
