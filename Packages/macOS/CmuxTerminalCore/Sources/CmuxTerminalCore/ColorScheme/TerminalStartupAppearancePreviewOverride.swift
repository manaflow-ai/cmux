#if DEBUG
/// A DEBUG-only override of terminal config loading used by the startup
/// appearance preview debug panel.
///
/// The terminal config loader (`GhosttyConfig.loadFromDisk`) consults this seam
/// so it no longer reaches up into the app target's
/// `GhosttyStartupAppearancePreviewState`. The app sets ``installed`` from the
/// selected preview profile; when no override is installed (the default, and the
/// only state in production-shaped runs), the loader takes its normal real-user
/// config path.
///
/// This is DEBUG-only scaffolding, so the process-wide mutable hook mirrors the
/// app-side `static var profile` it replaces; it carries no production behavior.
public struct TerminalStartupAppearancePreviewOverride: Sendable {
    /// Whether the loader should still read the real user config files. When
    /// `false`, ``previewConfigContents`` supplies synthetic config text instead.
    public let loadsRealUserConfig: Bool

    /// Synthetic config contents for the selected preview profile, resolved for
    /// the given color scheme. `nil` leaves the config untouched.
    public let previewConfigContents: @Sendable (TerminalColorSchemePreference) -> String?

    /// Creates a preview override.
    public init(
        loadsRealUserConfig: Bool,
        previewConfigContents: @escaping @Sendable (TerminalColorSchemePreference) -> String?
    ) {
        self.loadsRealUserConfig = loadsRealUserConfig
        self.previewConfigContents = previewConfigContents
    }

    /// The currently installed DEBUG preview override, or `nil` for the normal
    /// real-user-config load path.
    ///
    /// DEBUG-only mutable hook (justification above); the app target is the sole
    /// writer, from the startup-appearance debug panel.
    public nonisolated(unsafe) static var installed: TerminalStartupAppearancePreviewOverride?
}
#endif
