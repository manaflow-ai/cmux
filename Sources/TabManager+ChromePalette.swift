import CmuxSettings

extension TabManager {
    /// Applies a palette snapshot to this window and all existing workspaces.
    /// New workspaces inherit the same snapshot from ``chromePalette``.
    func applyChromePalette(_ palette: ChromePalette) {
        guard chromePalette != palette else { return }
        chromePalette = palette
        for workspace in tabs {
            workspace.applyChromePalette(palette)
        }
    }
}
