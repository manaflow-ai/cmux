/// `notifications.sounds` (``NotificationSoundPreferences``). A bad value keeps its default with a
/// diagnostic; a bad level rule is dropped and the other levels apply.
extension NotificationConfigParser {
    static func sounds(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> NotificationSoundPreferences {
        // Red stub: cmux.json's sounds are read in the next commit.
        _ = rules(root, "groups", diagnostics: &diagnostics)
        return NotificationSoundPreferences()
    }

    /// The rules of one level map (`notifications.sounds.<key>`), by id or name.
    private static func rules(_ root: JSONValue, _ key: String, diagnostics: inout [SettingsDiagnostic]) -> [String: NotificationSoundRule] {
        guard let reader = ConfigFieldReader(root, at: ["notifications", "sounds", key], diagnostics: &diagnostics) else { return [:] }
        var rules: [String: NotificationSoundRule] = [:]
        for (name, value) in reader.members {
            var problems: [String] = []
            let rule = NotificationSoundRule.parse(value, problems: &problems)
            for problem in problems {
                diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "notifications.sounds.\(key).\(name)", message: problem))
            }
            if let rule, !rule.isEmpty { rules[name] = rule }
        }
        return rules
    }
}
