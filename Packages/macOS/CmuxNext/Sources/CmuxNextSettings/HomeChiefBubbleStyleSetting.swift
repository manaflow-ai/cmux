/// `home.chiefBubbleStyle` in cmux.json: how the Chief chat's bubbles look. `imessage` (the default;
/// the founders like Messages' blue) is Messages' blue for the person and its grey for the Chief;
/// `theme` takes the active theme's colours, the person's the theme's accent and the Chief's the
/// theme's surface (Leo 2026-10-19: a themed option for cmux's tinted glass themes). Looks only, so
/// agents may set it.
public nonisolated struct HomeChiefBubbleStyleSetting {
    public nonisolated init() {}
    public static let configPath = ["home", "chiefBubbleStyle"]
    public static let key = configPath.joined(separator: ".")
    public static let iMessage = "imessage", theme = "theme"
    public static let styles = [iMessage, theme]
    public static let defaultStyle = iMessage

    /// The style id; one that is not a style is the default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (String, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (defaultStyle, nil) }
        guard let id = value.stringValue, styles.contains(id) else {
            return (defaultStyle, SettingsDiagnostic(kind: .invalidValue, path: key, message: "expected one of " + styles.joined(separator: ", ")))
        }
        return (id, nil)
    }
}
