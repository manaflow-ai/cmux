import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextWindowRules

/// `notifications.*` in cmux.json (the attention ring is
/// `PaneRingConfigParser.attention`). A bad value keeps its default with a
/// diagnostic.
enum NotificationConfigParser {
    /// Asks cmux-window-rules `notification_settings` (`window_notifications_settings_parse`), which
    /// also reads `feed.*`. When the FFI does not answer, every field keeps its default.
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> NotificationPreferences {
        guard let parsed = WindowRules().call("window_notifications_settings_parse", Request(root: root), as: Parsed.self) else {
            return NotificationPreferences()
        }
        diagnostics += parsed.diagnostics.map(\.diagnostic)
        return parsed.prefs.preferences
    }

    private struct Request: Encodable { var root: JSONValue }
}
