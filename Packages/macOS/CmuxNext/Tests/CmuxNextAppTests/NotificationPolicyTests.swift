@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// The notification rules as tables (plans/cmux-next/notifications.md).
struct NotificationPolicyTests {
    /// The daemon names the source (`notification-source-v1`); `daemon`
    /// producers and daemons without sources use the agent settings.
    @Test func daemonSourcesMapToTheSourceSettings() {
        #expect(NotificationCenterService.source("cli") == .cli)
        #expect(NotificationCenterService.source("terminal") == .terminal)
        #expect(NotificationCenterService.source("agent") == .agent)
        #expect(NotificationCenterService.source("daemon") == .agent)
        #expect(NotificationCenterService.source(nil) == .agent)
    }

    @Test func dismissalModesClearOnTheirTriggers() {
        let table: [NotificationDismissal: Set<NotificationTrigger>] = [
            .focus: [.focus, .click, .keystroke, .open],
            .click: [.click, .keystroke, .open],
            .keystroke: [.keystroke, .open],
            .explicit: [.open],
            .timeout: [.open, .timeout],
            .never: [],
        ]
        let triggers: [NotificationTrigger] = [.focus, .click, .keystroke, .open, .timeout]
        for (mode, clearing) in table {
            for trigger in triggers {
                #expect(NotificationPolicy.clears(trigger, mode: mode) == clearing.contains(trigger), "\(mode) \(trigger)")
            }
        }
    }

    @Test func defaultIsKeystrokeNotFocus() {
        let prefs = NotificationPreferences()
        #expect(prefs.dismissal == .keystroke)
        #expect(!NotificationPolicy.clears(.focus, mode: prefs.dismissal))
        #expect(NotificationPolicy.clears(.keystroke, mode: prefs.dismissal))
        // A notification on the pane you are looking at stays until you type.
        let decision = NotificationPolicy.decide(.init(source: .cli, paneIsViewed: true, appActive: true), prefs: prefs)
        #expect(!decision.acknowledge)
        #expect(decision.attention)
        #expect(!decision.desktop)
        #expect(decision.sound == nil)
    }

    @Test func focusModeReadsAViewedPaneAtOnce() {
        var prefs = NotificationPreferences()
        prefs.dismissal = .focus
        let decision = NotificationPolicy.decide(.init(source: .agent, paneIsViewed: true, appActive: true), prefs: prefs)
        #expect(decision.acknowledge)
        #expect(!decision.attention)
    }

    @Test func desktopModes() {
        var prefs = NotificationPreferences()
        let background = NotificationPolicy.Arrival(source: .agent, paneIsViewed: false, appActive: true)
        let inactive = NotificationPolicy.Arrival(source: .agent, paneIsViewed: false, appActive: false)
        let viewed = NotificationPolicy.Arrival(source: .agent, paneIsViewed: true, appActive: true)
        #expect(NotificationPolicy.decide(background, prefs: prefs).desktop)
        #expect(!NotificationPolicy.decide(viewed, prefs: prefs).desktop)
        prefs.desktop = .whenInactive
        #expect(!NotificationPolicy.decide(background, prefs: prefs).desktop)
        #expect(NotificationPolicy.decide(inactive, prefs: prefs).desktop)
        prefs.desktop = .always
        #expect(NotificationPolicy.decide(viewed, prefs: prefs).desktop)
        prefs.desktop = .never
        #expect(!NotificationPolicy.decide(inactive, prefs: prefs).desktop)
    }

    @Test func quietHoursMuteAndPerSourceOverrides() {
        var prefs = NotificationPreferences()
        prefs.quietHours = QuietHours(start: 22 * 60, end: 7 * 60)
        var night = NotificationPolicy.Arrival(source: .agent)
        night.minuteOfDay = 23 * 60
        let quiet = NotificationPolicy.decide(night, prefs: prefs)
        #expect(!quiet.desktop && quiet.sound == nil && quiet.attention)
        night.minuteOfDay = 12 * 60
        #expect(NotificationPolicy.decide(night, prefs: prefs).desktop)

        var muted = NotificationPolicy.Arrival(source: .agent)
        muted.workspaceMuted = true
        let silent = NotificationPolicy.decide(muted, prefs: prefs)
        #expect(!silent.desktop && silent.sound == nil && !silent.attention && !silent.acknowledge)

        var overrides = NotificationSourceOverrides()
        overrides.desktop = false
        overrides.sound = "Glass"
        overrides.dismissal = .timeout
        prefs.sources[.terminal] = overrides
        let terminal = NotificationPolicy.decide(.init(source: .terminal), prefs: prefs)
        #expect(!terminal.desktop)
        #expect(terminal.sound == "Glass")
        #expect(terminal.timeout == prefs.timeoutSeconds)
        #expect(NotificationPolicy.decide(.init(source: .cli), prefs: prefs).sound == "default")
    }

    @Test func typingInThePaneSuppresses() {
        var prefs = NotificationPreferences()
        var arrival = NotificationPolicy.Arrival(source: .agent)
        arrival.typedAgo = 1
        #expect(!NotificationPolicy.decide(arrival, prefs: prefs).acknowledge)
        prefs.suppressWhileTypingSeconds = 2
        let decision = NotificationPolicy.decide(arrival, prefs: prefs)
        #expect(decision.acknowledge && !decision.attention && !decision.desktop)
        arrival.typedAgo = 3
        #expect(!NotificationPolicy.decide(arrival, prefs: prefs).acknowledge)
    }

    @Test func quietHoursWrapPastMidnight() {
        let night = QuietHours(start: 22 * 60, end: 7 * 60)
        #expect(night.contains(minuteOfDay: 23 * 60))
        #expect(night.contains(minuteOfDay: 6 * 60))
        #expect(!night.contains(minuteOfDay: 12 * 60))
        let lunch = QuietHours(start: 12 * 60, end: 13 * 60)
        #expect(lunch.contains(minuteOfDay: 12 * 60 + 30))
        #expect(!lunch.contains(minuteOfDay: 13 * 60))
        #expect(QuietHours.minutes("07:30") == 450)
        #expect(QuietHours.minutes("25:00") == nil)
    }
}
