import CmuxNextSettings
import Testing

/// The unread ring stays until the person clicks into its pane or types in it (Austin, 2026-10-20:
/// "the blue ring should persist until I go in and click on that specific pane"; Lawrence,
/// 2026-10-19, u2414: "you click and it gets dismissed"). The 2026-10-19 default, `focus`, also
/// read a pane when it merely took focus (a workspace switch, a keyboard move, the palette), so a
/// ring cleared before the person had looked at its pane. The default is now `click`.
struct UnreadDismissDefaultsTests {
    @Test func aNotificationClearsWhenItsPaneIsClickedByDefault() {
        #expect(NotificationPreferences().dismissal == .click)
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.notifications.dismissal == .click, "an empty cmux-next.json reads with the click rule")
        #expect(SettingsSchema.descriptor(for: ["notifications", "dismissal"])?.defaultValue == .string("click"))
    }

    /// A click in the pane, a key typed in it and opening the notification read it by default.
    @Test(arguments: [NotificationTrigger.click, .keystroke, .open])
    func goingIntoThePaneReadsItByDefault(_ trigger: NotificationTrigger) {
        let policy = NotificationPolicy(prefs: NotificationPreferences())
        for source in NotificationSource.allCases {
            #expect(policy.clears(trigger, for: source), "\(trigger) leaves a \(source) notification unread")
        }
    }

    /// Focus alone (a workspace switch, a keyboard move, Cmd+1-9, the palette) keeps the ring.
    @Test func focusAloneKeepsTheRingByDefault() {
        let policy = NotificationPolicy(prefs: NotificationPreferences())
        for source in NotificationSource.allCases {
            #expect(!policy.clears(.focus, for: source), "focus read a \(source) notification")
        }
    }

    @Test func aTimeoutStillNeedsTheTimeoutMode() {
        #expect(!NotificationPolicy(prefs: NotificationPreferences()).clears(.timeout, for: .agent))
    }
}
