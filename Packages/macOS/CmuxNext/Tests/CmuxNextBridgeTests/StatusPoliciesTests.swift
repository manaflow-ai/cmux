import CmuxNextDesign
import Testing
@testable import CmuxNextBridge

/// Inferred command busy and run notifications follow the settings.
struct StatusPoliciesTests {
    @Test func commandBusyShowsAfterTheThresholdOnlyWhenEnabled() {
        var settings = StatusBehaviorSettings()
        #expect(settings.inferCommandBusy && settings.inferCommandBusyAfter == 3)
        #expect(!settings.showsCommandBusy(sinceMs: 1_000, nowMs: 3_999))
        #expect(settings.showsCommandBusy(sinceMs: 1_000, nowMs: 4_000))
        #expect(settings.commandBusyDeadlineMs(sinceMs: 1_000, nowMs: 2_000) == 4_000)
        #expect(settings.commandBusyDeadlineMs(sinceMs: 1_000, nowMs: 5_000) == nil)
        settings.inferCommandBusyAfter = 0
        #expect(settings.showsCommandBusy(sinceMs: 1_000, nowMs: 1_000))
        settings.inferCommandBusy = false
        #expect(!settings.showsCommandBusy(sinceMs: 0, nowMs: 99_999))
        #expect(settings.commandBusyDeadlineMs(sinceMs: 0, nowMs: 0) == nil)
    }

    @Test func runNotifiesWhenLongEnoughAndNotVisible() {
        var settings = StatusBehaviorSettings()
        #expect(settings.runNotifyMinimumSeconds == 10 && !settings.runNotifyWhenVisible)
        let visible = TerminalVisibility(tabSelected: true, paneOnScreen: true, windowShown: true, appActive: true)
        #expect(!settings.notifiesFinishedRun(durationMs: 9_999, visibility: .hidden))
        #expect(settings.notifiesFinishedRun(durationMs: 10_000, visibility: .hidden))
        #expect(!settings.notifiesFinishedRun(durationMs: 60_000, visibility: visible))
        // Any one hidden condition makes the terminal not visible.
        for hidden in [\TerminalVisibility.tabSelected, \.paneOnScreen, \.windowShown, \.appActive] {
            var partly = visible
            partly[keyPath: hidden] = false
            #expect(settings.notifiesFinishedRun(durationMs: 60_000, visibility: partly))
        }
        settings.runNotifyWhenVisible = true
        #expect(settings.notifiesFinishedRun(durationMs: 60_000, visibility: visible))
    }

    @Test func styleHintsCountOnlyFromHonoredSources() {
        let hinted = StatusReport(id: "a", source: .agent, state: .busy, style: .native)
        #expect(StatusStack.resolve([hinted]).style == .native)
        #expect(StatusStack.resolve([hinted], honoring: [.explicit]).style == nil)
        #expect(StatusStack.resolve([hinted], honoring: []).style == nil)
    }
}
