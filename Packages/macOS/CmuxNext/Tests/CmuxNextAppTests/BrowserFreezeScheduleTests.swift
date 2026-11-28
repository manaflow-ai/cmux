import CmuxNextHibernation
import CmuxNextSettings
import Testing

@MainActor @Suite struct BrowserFreezeScheduleTests {
    @Test func loadingPagesWaitForAnEventRatherThanADeadline() {
        let schedule = BrowserFreezeSchedule()
        let now = ContinuousClock.now
        let pages = [HibernationPlanner.Candidate(key: "loading", hiddenFor: 60)]
        schedule.keep("loading", at: now)
        let loading = schedule.plan(.fallback, hidden: pages, now: now, eligible: { _ in false })
        #expect(loading.due.isEmpty)
        #expect(loading.nextCheck == nil)

        let settled = schedule.plan(.fallback, hidden: pages, now: now + .seconds(31), eligible: { _ in true })
        #expect(settled.due == ["loading"])
        #expect(settled.nextCheck == nil)
    }

    @Test func theEarliestHiddenOrBackoffDeadlineWins() {
        let schedule = BrowserFreezeSchedule()
        let now = ContinuousClock.now
        let pages = [
            HibernationPlanner.Candidate(key: "due", hiddenFor: 60),
            HibernationPlanner.Candidate(key: "kept", hiddenFor: 60),
            HibernationPlanner.Candidate(key: "new", hiddenFor: 25),
        ]
        schedule.keep("kept", at: now - .seconds(20))
        let first = schedule.plan(.fallback, hidden: pages, now: now, eligible: { _ in true })
        #expect(first.due == ["due"])
        #expect(first.nextCheck == 5)

        let expired = schedule.plan(.fallback, hidden: [pages[1]], now: now + .seconds(10), eligible: { _ in true })
        #expect(expired.due == ["kept"])
        #expect(expired.nextCheck == nil)
    }

    @Test func forgettingOrDisablingFreezingLeavesNoBackoffDeadline() {
        let schedule = BrowserFreezeSchedule()
        let now = ContinuousClock.now
        let pages = [HibernationPlanner.Candidate(key: "kept", hiddenFor: 60)]
        schedule.keep("kept", at: now)
        var disabled = BrowserHibernationSetting.fallback
        disabled.freezeSeconds = nil
        let off = schedule.plan(disabled, hidden: pages, now: now, eligible: { _ in true })
        #expect(off.due.isEmpty)
        #expect(off.nextCheck == nil)

        schedule.forget("kept")
        let cleared = schedule.plan(.fallback, hidden: pages, now: now, eligible: { _ in true })
        #expect(cleared.due == ["kept"])
        #expect(cleared.nextCheck == nil)
    }
}
