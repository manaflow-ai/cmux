/// The groups, panes and tabs Go to Workspace (Cmd-P) searches next to the
/// workspaces. The App implements it over its mirror and the sidebar.
public protocol PaletteNavigationSource: AnyObject {
    /// Every group, pane and tab, as of now.
    func navigationEntries() -> [PaletteNavigationEntry]
    /// Goes to `entry`: a group shows its first workspace (expanding the
    /// group), a pane or tab shows its workspace and takes focus.
    func open(_ entry: PaletteNavigationEntry)
}
