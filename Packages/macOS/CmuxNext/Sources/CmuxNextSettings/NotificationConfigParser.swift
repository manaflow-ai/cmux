public import CmuxNextDesign

/// `notifications.*` in cmux.json (the attention ring is
/// `PaneRingConfigParser.attention`). A bad value keeps its default with a
/// diagnostic.
enum NotificationConfigParser {
    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> NotificationPreferences {
        var prefs = NotificationPreferences()
        // `feed.*` sits outside `notifications`, so it is read before the early return below.
        prefs.feedMirror = feedMirror(root, diagnostics: &diagnostics)
        guard var reader = ConfigFieldReader(root, at: ["notifications"], diagnostics: &diagnostics) else { return prefs }
        if let value = reader.choice("dismissal", NotificationDismissal.self) { prefs.dismissal = value }
        if let value = reader.number("timeoutSeconds", range: NotificationPreferences.timeoutRange) { prefs.timeoutSeconds = value }
        if let value = reader.choice("desktop", DesktopNotificationMode.self) { prefs.desktop = value }
        if let value = reader.string("sound") { prefs.sound = value }
        if let value = reader.number("suppressWhileTypingSeconds", range: NotificationPreferences.typingRange) {
            prefs.suppressWhileTypingSeconds = value
        }
        if let value = reader.bool("dockBadge") { prefs.dockBadge = value }
        diagnostics += reader.diagnostics
        prefs.quietHours = quietHours(root, diagnostics: &diagnostics)
        prefs.mutedWorkspaces = mutedWorkspaces(root, diagnostics: &diagnostics)
        for source in NotificationSource.allCases {
            guard var entry = ConfigFieldReader(root, at: ["notifications", "sources", source.rawValue], diagnostics: &diagnostics) else { continue }
            var overrides = NotificationSourceOverrides()
            overrides.dismissal = entry.choice("dismissal", NotificationDismissal.self)
            overrides.color = entry.color("color") ?? nil
            overrides.sound = entry.string("sound")
            overrides.desktop = entry.bool("desktop")
            diagnostics += entry.diagnostics
            prefs.sources[source] = overrides
        }
        return prefs
    }

    /// `feed.mirrorNotifications.{agents, terminal}`.
    static func feedMirror(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> FeedMirrorPreferences {
        var mirror = FeedMirrorPreferences()
        guard var reader = ConfigFieldReader(root, at: ["feed", "mirrorNotifications"], diagnostics: &diagnostics) else { return mirror }
        if let value = reader.bool("agents") { mirror.agents = value }
        if let value = reader.choice("terminal", FeedTerminalMirror.self) { mirror.terminal = value }
        diagnostics += reader.diagnostics
        return mirror
    }

    private static func quietHours(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> QuietHours? {
        guard let value = root.value(at: ["notifications", "quietHours"]) else { return nil }
        if case .null = value { return nil }
        guard case .object(let members) = value,
              let start = members["start"]?.stringValue.flatMap(QuietHours.minutes),
              let end = members["end"]?.stringValue.flatMap(QuietHours.minutes) else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "notifications.quietHours",
                                                  message: "expected {\"start\": \"HH:MM\", \"end\": \"HH:MM\"}"))
            return nil
        }
        return QuietHours(start: start, end: end)
    }

    private static func mutedWorkspaces(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Set<String> {
        guard let value = root.value(at: ["notifications", "mutedWorkspaces"]) else { return [] }
        guard case .array(let items) = value else {
            diagnostics.append(SettingsDiagnostic(kind: .invalidValue, path: "notifications.mutedWorkspaces", message: "expected an array of workspace ids"))
            return []
        }
        return Set(items.compactMap(\.stringValue))
    }
}
