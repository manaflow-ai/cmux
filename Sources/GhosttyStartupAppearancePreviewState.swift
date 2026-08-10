import CmuxTerminalCore

enum GhosttyStartupAppearancePreviewState {
    #if DEBUG
    // The selected debug preview profile. Backed by the CmuxTerminalCore seam
    // (TerminalStartupAppearancePreviewOverride) so GhosttyConfig's loader, now
    // package-bound, never reaches back up into this app-target settings type.
    // The app is the sole writer of the override.
    private nonisolated(unsafe) static var storedProfile: GhosttyStartupAppearancePreviewProfile = .realUserConfig

    static var profile: GhosttyStartupAppearancePreviewProfile {
        get { storedProfile }
        set {
            storedProfile = newValue
            TerminalStartupAppearancePreviewOverride.installed = TerminalStartupAppearancePreviewOverride(
                loadsRealUserConfig: newValue.loadsRealUserConfig,
                previewConfigContents: { colorScheme in
                    newValue.previewConfigContents(preferredColorScheme: colorScheme)
                }
            )
        }
    }
    #else
    static let profile: GhosttyStartupAppearancePreviewProfile = .realUserConfig
    #endif
}
