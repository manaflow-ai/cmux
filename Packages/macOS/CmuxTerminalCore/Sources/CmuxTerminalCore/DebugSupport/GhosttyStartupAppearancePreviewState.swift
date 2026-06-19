/// The process-wide selected startup-appearance preview profile.
///
/// In DEBUG, the setter mirrors the selection into
/// ``TerminalStartupAppearancePreviewOverride/installed`` so the terminal config
/// loader (`GhosttyConfig.loadFromDisk`) reads the chosen profile without
/// reaching back up into the app target. The app's startup-appearance debug
/// panel is the sole writer.
///
/// This is DEBUG-only scaffolding: the mutable static mirrors the app-side state
/// it replaces (the LEARNINGS-sanctioned `#if DEBUG` static hook), carries no
/// production behavior, and is compiled to a plain inert `static var` in
/// non-DEBUG builds.
public enum GhosttyStartupAppearancePreviewState {
    #if DEBUG
    /// The selected debug preview profile. Backed by the
    /// ``TerminalStartupAppearancePreviewOverride`` seam so `GhosttyConfig`'s
    /// loader never reaches up into the app target. The app is the sole writer.
    ///
    /// DEBUG-only mutable hook (justification above); single-writer from the
    /// startup-appearance debug panel.
    private nonisolated(unsafe) static var storedProfile: GhosttyStartupAppearancePreviewProfile = .realUserConfig

    /// The selected debug preview profile; setting it installs the matching
    /// loader override.
    public static var profile: GhosttyStartupAppearancePreviewProfile {
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
    /// The selected debug preview profile. Inert in non-DEBUG builds.
    ///
    /// `nonisolated(unsafe)` is required by the package's strict-concurrency mode
    /// for a mutable non-isolated static; the app target's looser isolation did
    /// not need it. This branch is dead debug scaffolding in release builds.
    public nonisolated(unsafe) static var profile: GhosttyStartupAppearancePreviewProfile = .realUserConfig
    #endif
}
