public import CmuxNextDesign

/// `ui.reducedBackgrounds` in cmux.json: off by default, so windows draw what `appearance.*` asks
/// for. On, windows draw the plain theme background: no painting, shuffle, desktop or system
/// wallpaper (the app's, a workspace's or a pane's own pick) and no glass, frost or see-through
/// window, the way Reduce Transparency draws them. It overrides what is drawn while on and never
/// changes the `appearance.*` values, so turning it off restores them.
public nonisolated struct ReducedBackgroundsSetting {
    public nonisolated init() {}

    /// The window background drawn while it is on: opaque, no blur, whatever cmux.json or the
    /// Ghostty config ask for.
    public static let plainWindowBackground = WindowBackgroundOverride(opacity: 1, material: .unblurred)

    /// The window background the app draws for the person's `background`.
    ///
    /// - Parameter background: `appearance.backgroundOpacity` and `appearance.backgroundBlur`.
    /// - Parameter reduced: `ui.reducedBackgrounds`.
    /// - Returns: `background`, or ``plainWindowBackground`` while reduced.
    public static func drawn(_ background: WindowBackgroundOverride, reduced: Bool) -> WindowBackgroundOverride {
        reduced ? plainWindowBackground : background
    }

    /// A missing key is off with no diagnostic; a bad value is off plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "ui.reducedBackgrounds",
                                                 message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
