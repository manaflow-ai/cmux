/// `appearance.previousGlass` in cmux.json: off by default, so web pages draw the one glass system
/// (design/glass-system.md). On, they draw the glass numbers from before it: one tint for light and
/// dark, the old saturations, no lit top edge, the 70% see-through underlay, and content cards as
/// chrome glass (`WebTheme.glassLevels` is `previous`, webviews ui/glass/glass.css). Native surfaces
/// keep their own material; Reduce Transparency still draws every web glass solid.
public nonisolated struct PreviousGlassSetting {
    public nonisolated init() {}

    /// A missing key is off with no diagnostic; a bad value is off plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "appearance.previousGlass",
                                                 message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
