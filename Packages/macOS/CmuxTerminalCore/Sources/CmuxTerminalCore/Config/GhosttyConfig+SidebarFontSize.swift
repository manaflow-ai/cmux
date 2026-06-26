public import CoreGraphics

extension GhosttyConfig {
    /// Loads the sidebar tab-item font size from the user's ghostty config off the
    /// main actor. Parsing the config touches disk, so the read runs on a detached
    /// utility-priority task and only the resolved ``sidebarFontSize`` is returned.
    public static func loadSidebarFontSize() async -> CGFloat {
        await Task.detached(priority: .utility) {
            GhosttyConfig.load().sidebarFontSize
        }.value
    }
}
