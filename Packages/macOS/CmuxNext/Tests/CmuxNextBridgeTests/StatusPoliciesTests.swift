import CmuxNextDesign
import Testing
@testable import CmuxNextBridge

/// Inferred command busy and run notifications follow the settings.
struct StatusPoliciesTests {
    @Test func commandBusyShowsAfterTheThresholdOnlyWhenEnabled() {
        var settings = StatusBehaviorSettings()
        #expect(settings.inferCommandBusy && settings.inferCommandBusyAfter == 3)
        #expect(!StatusPolicies.showsCommandBusy(sinceMs: 1_000, nowMs: 3_999, settings: settings))
        #expect(StatusPolicies.showsCommandBusy(sinceMs: 1_000, nowMs: 4_000, settings: settings))
        #expect(StatusPolicies.commandBusyDeadlineMs(sinceMs: 1_000, nowMs: 2_000, settings: settings) == 4_000)
        #expect(StatusPolicies.commandBusyDeadlineMs(sinceMs: 1_000, nowMs: 5_000, settings: settings) == nil)
        settings.inferCommandBusyAfter = 0
        #expect(StatusPolicies.showsCommandBusy(sinceMs: 1_000, nowMs: 1_000, settings: settings))
        settings.inferCommandBusy = false
        #expect(!StatusPolicies.showsCommandBusy(sinceMs: 0, nowMs: 99_999, settings: settings))
        #expect(StatusPolicies.commandBusyDeadlineMs(sinceMs: 0, nowMs: 0, settings: settings) == nil)
    }

    @Test func runNotifiesWhenLongEnoughAndNotVisible() {
        var settings = StatusBehaviorSettings()
        #expect(settings.runNotifyMinimumSeconds == 10 && !settings.runNotifyWhenVisible)
        let visible = TerminalVisibility(tabSelected: true, paneOnScreen: true, windowShown: true, appActive: true)
        #expect(!StatusPolicies.notifiesFinishedRun(durationMs: 9_999, visibility: .hidden, settings: settings))
        #expect(StatusPolicies.notifiesFinishedRun(durationMs: 10_000, visibility: .hidden, settings: settings))
        #expect(!StatusPolicies.notifiesFinishedRun(durationMs: 60_000, visibility: visible, settings: settings))
        // Any one hidden condition makes the terminal not visible.
        for hidden in [\TerminalVisibility.tabSelected, \.paneOnScreen, \.windowShown, \.appActive] {
            var partly = visible
            partly[keyPath: hidden] = false
            #expect(StatusPolicies.notifiesFinishedRun(durationMs: 60_000, visibility: partly, settings: settings))
        }
        settings.runNotifyWhenVisible = true
        #expect(StatusPolicies.notifiesFinishedRun(durationMs: 60_000, visibility: visible, settings: settings))
    }

    @Test func styleHintsCountOnlyFromHonoredSources() {
        let hinted = StatusReport(id: "a", source: .agent, state: .busy, style: .native)
        #expect(StatusStack.resolve([hinted]).style == .native)
        #expect(StatusStack.resolve([hinted], honoring: [.explicit]).style == nil)
        #expect(StatusStack.resolve([hinted], honoring: []).style == nil)
    }
}
