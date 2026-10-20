import CmuxNextSettings
import Testing

/// Lawrence, 2026-10-19 (u2414): "the logic for it should be more similar to the logic for cmux
/// classic, where you click and it gets dismissed ... right now I can't dismiss it". Classic
/// (CmuxNotifications `NotificationDismissalContext`) reads a pane's notification when the pane
/// is focused in the active app, clicked, or typed in. cmux-next's default was `keystroke`, so a
/// focus or a click kept the ring until a key reached the pane, and a page or Markdown pane the
/// person never types into kept it until Mark Read. The default is now `focus`, classic's rule.
struct UnreadDismissDefaultsTests {
    @Test func aNotificationClearsWhenItsPaneIsFocusedByDefault() {
        #expect(NotificationPreferences().dismissal == .focus)
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.notifications.dismissal == .focus, "an empty cmux-next.json reads with classic's rule")
        #expect(SettingsSchema.descriptor(for: ["notifications", "dismissal"])?.defaultValue == .string("focus"))
    }

    /// Every way a person looks at a pane reads it by default: focusing it (a click on its tab,
    /// a keyboard switch, Cmd+1-9, the palette, `cmux focus`: every one settles focus and comes
    /// here as `focus`), a click in it, a key typed in it, and opening the notification.
    @Test(arguments: [NotificationTrigger.focus, .click, .keystroke, .open])
    func everyLookAtThePaneReadsItByDefault(_ trigger: NotificationTrigger) {
        let policy = NotificationPolicy(prefs: NotificationPreferences())
        for source in NotificationSource.allCases {
            #expect(policy.clears(trigger, for: source), "\(trigger) leaves a \(source) notification unread")
        }
    }

    @Test func aTimeoutStillNeedsTheTimeoutMode() {
        #expect(!NotificationPolicy(prefs: NotificationPreferences()).clears(.timeout, for: .agent))
    }
}
