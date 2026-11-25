/// `notifications.sounds` (``NotificationSoundPreferences``). A bad value keeps its default with a
/// diagnostic; a bad level rule is dropped and the other levels apply.
extension NotificationConfigParser {
    static func sounds(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> NotificationSoundPreferences {
        var sounds = NotificationSoundPreferences()
        let path = ["notifications", "sounds"]
        guard var reader = ConfigFieldReader(root, at: path, diagnostics: &diagnostics) else { return sounds }
        if let value = reader.number("volume", range: NotificationSoundPreferences.volumeRange) { sounds.volume = value }
        if let value = reader.choice("when", NotificationSoundTiming.self) { sounds.when = value }
        if let value = reader.number("cooldownSeconds", range: NotificationSoundPreferences.cooldownRange) { sounds.cooldownSeconds = value }
        diagnostics += reader.diagnostics
        if var events = ConfigFieldReader(root, at: path + ["events"], diagnostics: &diagnostics) {
            for name in events.members.keys.sorted() {
                guard let event = NotificationSoundEvent(rawValue: name) else {
                    diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "notifications.sounds.events.\(name)",
                                                          message: "unknown event; expected one of \(NotificationSoundEvent.allCases.map(\.rawValue).joined(separator: ", "))"))
                    continue
                }
                if let sound = events.string(name) { sounds.events[event] = sound }
            }
            diagnostics += events.diagnostics
        }
        sounds.groups = rules(root, "groups", diagnostics: &diagnostics)
        sounds.workspaces = rules(root, "workspaces", diagnostics: &diagnostics)
        sounds.agents = Dictionary(rules(root, "agents", diagnostics: &diagnostics).map { ($0.key.lowercased(), $0.value) },
                                   uniquingKeysWith: { first, _ in first })
        return sounds
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
