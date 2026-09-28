import Foundation

@MainActor
extension TabManager {
    /// Applies a Group By choice made in the sidebar Views menu or the command
    /// palette. Grouping only draws in the default workspaces sidebar, so the
    /// choice also switches away from a custom or extension sidebar view;
    /// otherwise picking a mode would look like it did nothing. Socket and CLI
    /// callers set `sidebarGroupBy.mode` directly and leave the view alone.
    func selectSidebarGroupBy(_ mode: SidebarGroupByMode) {
        sidebarGroupBy.mode = mode
        let selection = CmuxExtensionSidebarSelection.self
        let persisted = UserDefaults.standard.string(forKey: selection.defaultsKey) ?? selection.defaultProviderId
        if persisted != selection.defaultProviderId {
            selection.setProviderId(selection.defaultProviderId)
        }
    }
}
