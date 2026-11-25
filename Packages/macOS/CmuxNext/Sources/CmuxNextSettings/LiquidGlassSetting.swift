/// `appearance.liquidGlass` in cmux.json: off by default (Lawrence, standup 2026-11-19), so web
/// pages draw the solid look Reduce Transparency draws: the opaque surface, no blur, a hairline rim
/// (`WebTheme.glass` is `off`). On, they draw their glass (the composer, Session Info, menus,
/// popovers, tooltips and hover cards). Native surfaces keep their own material.
public nonisolated struct LiquidGlassSetting {
    public nonisolated init() {}

    /// A missing key is off with no diagnostic; a bad value is off plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "appearance.liquidGlass",
                                                 message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
