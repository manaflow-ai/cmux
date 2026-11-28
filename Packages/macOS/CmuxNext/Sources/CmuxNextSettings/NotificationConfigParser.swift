public import CmuxNextDesign

/// `notifications.*` and `feed.mirrorNotifications` in cmux.json (the attention ring is
/// `PaneRingConfigParser.attention`), read by Rust (`notifications.parse`). A bad value keeps its
/// default with a diagnostic.
enum NotificationConfigParser {
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> NotificationPreferences {
        let reply = SettingsRust.answer("notifications.parse", ["root": root.keeping([["notifications"], ["feed"]])])
        diagnostics += (reply["diagnostics"]?.arrayValue ?? []).compactMap { item in
            guard let path = item["path"]?.stringValue, let message = item["message"]?.stringValue else { return nil }
            return SettingsDiagnostic(kind: .invalidValue, path: path, message: message)
        }
        var prefs = SettingsRust.decode(reply["prefs"], as: NotificationPreferences.self) ?? NotificationPreferences()
        for (source, entry) in reply["prefs"]?["sources"]?.objectValue ?? [:] {
            guard let source = NotificationSource(rawValue: source) else { continue }
            prefs.sources[source]?.color = entry["color"]?.stringValue.flatMap(ThemeRGB.init(cssHex:))
        }
        return prefs
    }
}
