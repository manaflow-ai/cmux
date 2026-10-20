import CmuxFoundation

extension GhosttyConfig {
    /// Config keys cmux reads from the user's Ghostty config that Ghostty itself
    /// does not know.
    ///
    /// ``parse(_:loadingThemesImmediatelyFor:)`` handles these keys, and
    /// Ghostty's own parser reports each one as an unknown field. The config
    /// error notice uses this set to drop that expected noise.
    public static let cmuxOwnedKeys: Set<String> = [
        sidebarFontSizeKey,
        surfaceTabBarFontSizeKey,
        sidebarBackgroundKey,
        sidebarTintOpacityKey,
    ]

    static let sidebarFontSizeKey = CmuxGhosttyConfigSettingEditor.sidebarFontSizeKey
    static let surfaceTabBarFontSizeKey = CmuxGhosttyConfigSettingEditor.surfaceTabBarFontSizeKey
    static let sidebarBackgroundKey = "sidebar-background"
    static let sidebarTintOpacityKey = "sidebar-tint-opacity"
}
