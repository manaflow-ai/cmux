import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `notifications.*` in cmux.json.
@Suite struct NotificationSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaults() throws {
        let prefs = try parse("{}").notifications
        #expect(prefs == NotificationPreferences())
        #expect(prefs.dismissal == .keystroke)
        #expect(prefs.desktop == .unlessFocused)
        #expect(prefs.sound == "default")
        #expect(prefs.dockBadge)
    }

    @Test func readsEveryField() throws {
        let prefs = try parse(#"""
        {"notifications": {
          "dismissal": "timeout", "timeoutSeconds": 90, "desktop": "whenInactive", "sound": "Glass",
          "quietHours": {"start": "22:00", "end": "07:00"}, "suppressWhileTypingSeconds": 3, "dockBadge": false,
          "mutedWorkspaces": ["ws-1", "ws-2"],
          "sources": {"agent": {"color": "#FFAA00", "dismissal": "explicit", "sound": "Ping", "desktop": true},
                      "terminal": {"desktop": false}},
          "attention": {"style": "steady"}
        }}
        """#).notifications
        #expect(prefs.dismissal == .timeout)
        #expect(prefs.timeoutSeconds == 90)
        #expect(prefs.desktop == .whenInactive)
        #expect(prefs.sound == "Glass")
        #expect(prefs.quietHours == QuietHours(start: 22 * 60, end: 7 * 60))
        #expect(prefs.suppressWhileTypingSeconds == 3)
        #expect(!prefs.dockBadge)
        #expect(prefs.mutedWorkspaces == ["ws-1", "ws-2"])
        #expect(prefs.sources[.agent]?.color == ThemeRGB(hex: 0xFFAA00))
        #expect(prefs.dismissal(for: .agent) == .explicit)
        #expect(prefs.sound(for: .agent) == "Ping")
        #expect(!prefs.postsDesktop(for: .terminal))
        #expect(prefs.dismissal(for: .cli) == .timeout)
    }

    @Test func badValuesKeepDefaults() throws {
        let snapshot = try parse(#"{"notifications": {"dismissal": "sometimes", "desktop": 3, "quietHours": {"start": "9"}}}"#)
        #expect(snapshot.notifications.dismissal == .keystroke)
        #expect(snapshot.notifications.desktop == .unlessFocused)
        #expect(snapshot.notifications.quietHours == nil)
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["notifications.dismissal", "notifications.desktop", "notifications.quietHours"])
    }

    @Test func feedMirrorDefaultsKeepTerminalTextOnTheMac() throws {
        let mirror = try parse("{}").notifications.feedMirror
        #expect(mirror.agents)
        #expect(mirror.terminal == .off)
        let set = try parse(#"{"feed": {"mirrorNotifications": {"agents": false, "terminal": "title"}}}"#)
        #expect(set.notifications.feedMirror.agents == false)
        #expect(set.notifications.feedMirror.terminal == .title)
        let bad = try parse(#"{"feed": {"mirrorNotifications": {"terminal": "everything"}}}"#)
        #expect(bad.notifications.feedMirror.terminal == .off)
        #expect(bad.diagnostics.contains { $0.path.hasPrefix("feed.mirrorNotifications.terminal") })
    }
}

