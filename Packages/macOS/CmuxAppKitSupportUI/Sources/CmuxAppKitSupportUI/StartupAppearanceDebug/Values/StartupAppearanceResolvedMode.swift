#if canImport(AppKit)
#if DEBUG

/// The AppKit appearance the Startup Appearance panel applies for the "Stored App
/// Setting" preview mode.
///
/// This is the normalized projection of the app-target `AppearanceMode` the legacy
/// `applyAppearance(.stored)` branch switched over: `system`/`auto` cleared the
/// `NSApplication` appearance (``unspecified``), `light`/`dark` forced the matching
/// appearance. Returning this from the ``StartupAppearanceReloading`` seam keeps
/// the app-target appearance vocabulary out of this package while preserving the
/// exact mapping.
public enum StartupAppearanceResolvedMode: Sendable {
    /// Clear the `NSApplication` appearance (the legacy `system`/`auto` branch).
    case unspecified
    /// Force the light (aqua) appearance.
    case light
    /// Force the dark (darkAqua) appearance.
    case dark
}

#endif
#endif
