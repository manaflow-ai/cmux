import CmuxNextSettings
import Testing

/// Under the `focus` dismissal (the default since #25701), an arrival on the pane being viewed is
/// read at once and sets no ring. `notifications.sounds.when = always` means always: that arrival
/// still sounds. Every other timing keeps a viewed pane silent, and a muted workspace or quiet
/// hours still silence it.
struct NotificationSoundOnSightTests {
    private static func viewed(_ when: NotificationSoundTiming, muted: Bool = false, quiet: Bool = false) -> NotificationPolicy.Decision {
        var prefs = NotificationPreferences()
        prefs.sounds.when = when
        if quiet { prefs.quietHours = QuietHours(start: 0, end: 24 * 60 - 1) }
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.paneIsViewed = true
        arrival.appActive = true
        arrival.workspaceMuted = muted
        return NotificationPolicy(prefs: prefs).decide(arrival)
    }

    @Test(arguments: NotificationSoundTiming.allCases)
    func aViewedPaneIsReadAtOnceUnderEveryTiming(_ when: NotificationSoundTiming) {
        let decision = Self.viewed(when)
        #expect(NotificationPreferences().dismissal == .focus)
        #expect(decision.acknowledge && !decision.attention, "\(when) changed the focus acknowledgement")
        #expect(!decision.alerts && !decision.desktop && decision.bounce == nil)
    }

    @Test func alwaysSoundsForAViewedPane() {
        let decision = Self.viewed(.always)
        #expect(decision.sound == "default")
        #expect(decision.soundEvent == .finished)
    }

    @Test(arguments: NotificationSoundTiming.allCases.filter { $0 != .always })
    func everyOtherTimingKeepsAViewedPaneSilent(_ when: NotificationSoundTiming) {
        #expect(Self.viewed(when).sound == nil, "\(when) sounded for a viewed pane")
    }

    @Test func aMutedWorkspaceOrQuietHoursStillSilenceAlways() {
        #expect(Self.viewed(.always, muted: true).sound == nil)
        #expect(Self.viewed(.always, quiet: true).sound == nil)
    }
}
