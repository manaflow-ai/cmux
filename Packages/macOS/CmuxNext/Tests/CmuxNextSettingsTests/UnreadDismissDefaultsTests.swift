import CmuxNextSettings
import Testing

/// Attention is one on/off state per pane, cleared when the pane is selected, including by
/// entering its workspace, as in cmux classic (https://github.com/manaflow-ai/cmux/issues/25662).
/// The 2026-10-20 default, `click`, kept the ring through selection, and every later event on the
/// pane the person was already looking at rang it again, so it came back several times before it
/// cleared. The default is `focus`; `click` stays a choice in Settings.
struct UnreadDismissDefaultsTests {
    @Test func aNotificationClearsWhenItsPaneIsSelectedByDefault() {
        #expect(NotificationPreferences().dismissal == .focus)
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.notifications.dismissal == .focus, "an empty cmux-next.json reads with the focus rule")
        #expect(SettingsSchema.descriptor(for: ["notifications", "dismissal"])?.defaultValue == .string("focus"))
    }

    /// Selecting the pane (entering its workspace, a keyboard move, a click), a key typed in it and
    /// opening the notification read it by default.
    @Test(arguments: [NotificationTrigger.focus, .click, .keystroke, .open])
    func selectingThePaneReadsItByDefault(_ trigger: NotificationTrigger) {
        let policy = NotificationPolicy(prefs: NotificationPreferences())
        for source in NotificationSource.allCases {
            #expect(policy.clears(trigger, for: source), "\(trigger) leaves a \(source) notification unread")
        }
    }

    /// An event on the pane the person is looking at is read at once: no ring comes back.
    @Test func anEventOnTheSelectedPaneSetsNoRingByDefault() {
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.paneIsViewed = true
        arrival.appActive = true
        let decision = NotificationPolicy(prefs: NotificationPreferences()).decide(arrival)
        #expect(decision.acknowledge && !decision.attention, "an event on the selected pane rang it again")
    }

    @Test func aTimeoutStillNeedsTheTimeoutMode() {
        #expect(!NotificationPolicy(prefs: NotificationPreferences()).clears(.timeout, for: .agent))
    }
}
