/// `home.bubbleColors.{sent,sentText,received,receivedText}` in cmux.json: the bubble colours
/// every Home chat starts with (user 2026-10-28: bubble and text colours, per chat). Each is a
/// `#RRGGBB` colour; unset or `"theme"` keeps the bubble style's (Messages' blue and grey by
/// default). A chat's own Chat Colors… choice goes over these. Looks only, so agents may set it.
public nonisolated struct HomeBubbleColorsSetting {
    public nonisolated init() {}
    public static let configPath = ["home", "bubbleColors"]
    /// The four roles, in the order Settings lists them.
    public static let roles = ["sent", "sentText", "received", "receivedText"]

    /// Each role set to a colour, as `#RRGGBB` text (a bad value is left out plus a diagnostic).
    static func parse(_ root: JSONValue) -> ([String: String], [SettingsDiagnostic]) {
        var diagnostics: [SettingsDiagnostic] = []
        guard var reader = ConfigFieldReader(root, at: configPath, diagnostics: &diagnostics) else { return ([:], diagnostics) }
        var hexes: [String: String] = [:]
        for role in roles {
            if case .some(.some(let color)) = reader.color(role) { hexes[role] = color.withAlpha(1).description }
        }
        return (hexes, diagnostics + reader.diagnostics)
    }
}
