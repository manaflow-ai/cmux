#if canImport(AppKit)
#if DEBUG

/// The appearance the Startup Appearance debug panel forces while previewing a
/// startup config.
///
/// ``stored`` defers to the persisted app setting (resolved through the
/// ``StartupAppearanceReloading`` seam); ``light``/``dark`` force the matching
/// AppKit appearance. The raw values are kept byte-identical to the legacy
/// app-target enum so the panel's behavior is unchanged. The display labels are
/// localized app-side and supplied through ``StartupAppearanceDebugStrings``;
/// this value type carries none of them.
public enum StartupAppearancePreviewMode: String, CaseIterable, Identifiable, Sendable {
    /// Defer to the persisted app appearance setting.
    case stored
    /// Force the light (aqua) appearance.
    case light
    /// Force the dark (darkAqua) appearance.
    case dark

    /// Stable identity for SwiftUI iteration and selection.
    public var id: String { rawValue }
}

#endif
#endif
