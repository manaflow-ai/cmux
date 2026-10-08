import Foundation
import Testing
@testable import CmuxSidebar

@Suite
struct SidebarTipsScheduleTests {
    private let schedule = SidebarTipsSchedule()
    private let tipIDs = ["a", "b", "c"]
    private let now = Date(timeIntervalSince1970: 1_791_417_600)

    @Test func freshProgressOffersOneUnseenTip() {
        let fresh = SidebarTipsProgress()
        #expect(schedule.showsUnopenedIndicator(fresh))
        #expect(schedule.automaticTip(fresh, tipIDs: tipIDs, now: now) == "a")
        let opened = schedule.opened(fresh, tipIDs: tipIDs, now: now)
        #expect(opened.currentTipID == "a")
        #expect(opened.seenTipIDs == ["a"])
        #expect(opened.lastOpenedAt == now)
        #expect(!schedule.showsUnopenedIndicator(opened))
    }

    @Test func optingOutStillAllowsManualViewingAndCanBeReenabled() {
        var progress = SidebarTipsProgress(automaticTipsDisabled: true)
        #expect(schedule.automaticTip(progress, tipIDs: tipIDs, now: now) == nil)
        #expect(!schedule.showsUnopenedIndicator(progress))
        progress = schedule.opened(progress, tipIDs: tipIDs, now: now)
        #expect(progress.currentTipID == "a")
        #expect(progress.automaticTipsDisabled)
        #expect(schedule.automaticTip(progress, tipIDs: tipIDs, now: now.addingTimeInterval(172_800)) == nil)
        progress.automaticTipsDisabled = false
        #expect(schedule.automaticTip(progress, tipIDs: tipIDs, now: now.addingTimeInterval(172_800)) == "b")
        #expect(!schedule.showsUnopenedIndicator(progress))
    }

    @Test func manualViewingConsumesTheSameRollingDayAsAutomaticViewing() {
        let opened = schedule.opened(SidebarTipsProgress(), tipIDs: tipIDs, now: now)
        #expect(schedule.automaticTip(opened, tipIDs: tipIDs, now: now.addingTimeInterval(86_399)) == nil)
        #expect(schedule.automaticTip(opened, tipIDs: tipIDs, now: now.addingTimeInterval(86_400)) == "b")
    }

    @Test func crossingMidnightDoesNotCauseAnotherReminder() throws {
        let late = try #require(Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: now))
        let opened = schedule.opened(SidebarTipsProgress(), tipIDs: tipIDs, now: late)
        #expect(schedule.automaticTip(opened, tipIDs: tipIDs, now: late.addingTimeInterval(120)) == nil)
    }

    @Test func anEarlierClockDoesNotReopenTips() {
        let opened = schedule.opened(SidebarTipsProgress(), tipIDs: tipIDs, now: now)
        #expect(schedule.automaticTip(opened, tipIDs: tipIDs, now: now.addingTimeInterval(-86_400)) == nil)
    }

    @Test func exhaustedLegacyHistoryAndEmptyCatalogSuppressReminders() {
        let progress = SidebarTipsProgress(seenTipIDs: Set(tipIDs))
        #expect(schedule.automaticTip(progress, tipIDs: tipIDs, now: now) == nil)
        #expect(schedule.automaticTip(SidebarTipsProgress(), tipIDs: [], now: now) == nil)
        #expect(schedule.opened(progress, tipIDs: [], now: now) == progress)
        #expect(schedule.automaticTip(progress, tipIDs: tipIDs + ["new"], now: now) == "new")
    }

    @Test func everyManualOpeningAdvancesAndSkipsViewedTips() {
        var opened = schedule.opened(SidebarTipsProgress(), tipIDs: tipIDs, now: now)
        opened = schedule.opened(opened, tipIDs: tipIDs, now: now)
        #expect(opened.currentTipID == "b")
        opened = schedule.selected(opened, tipID: "c")
        let next = schedule.opened(opened, tipIDs: tipIDs + ["new"], now: now)
        #expect(next.currentTipID == "new")
        #expect(next.seenTipIDs == Set(tipIDs + ["new"]))
        #expect(!schedule.showsUnopenedIndicator(next))
    }

    @Test func exhaustedCatalogRotatesWeeklyWithoutAdvancingTwice() throws {
        let progress = SidebarTipsProgress(
            currentTipID: "c", seenTipIDs: Set(tipIDs), lastOpenedAt: now
        )
        let week: TimeInterval = 7 * 86_400
        #expect(schedule.automaticTip(progress, tipIDs: tipIDs, now: now.addingTimeInterval(week - 1)) == nil)
        let nextTime = now.addingTimeInterval(week)
        let chosen = try #require(schedule.automaticTip(progress, tipIDs: tipIDs, now: nextTime))
        #expect(chosen == "a")
        let opened = schedule.opened(progress, tipIDs: tipIDs, now: nextTime, preferredTipID: chosen)
        #expect(opened.currentTipID == "a")
        #expect(opened.seenTipIDs == Set(tipIDs))
        #expect(schedule.automaticTip(opened, tipIDs: tipIDs, now: nextTime.addingTimeInterval(week)) == "b")
    }

    @Test func manualOpeningRestartsWeeklyCooldownAndOptOutSuppressesRefreshers() {
        let progress = SidebarTipsProgress(currentTipID: "c", seenTipIDs: Set(tipIDs), lastOpenedAt: now)
        let manualTime = now.addingTimeInterval(6 * 86_400)
        var opened = schedule.opened(progress, tipIDs: tipIDs, now: manualTime)
        #expect(schedule.automaticTip(opened, tipIDs: tipIDs, now: now.addingTimeInterval(7 * 86_400)) == nil)
        let nextTime = manualTime.addingTimeInterval(7 * 86_400)
        #expect(schedule.automaticTip(opened, tipIDs: tipIDs, now: nextTime) == "b")
        opened.automaticTipsDisabled = true
        #expect(schedule.automaticTip(opened, tipIDs: tipIDs, now: nextTime) == nil)
    }

    @Test func newCatalogEntriesUseDailyCadenceAfterExhaustion() {
        let progress = SidebarTipsProgress(currentTipID: "c", seenTipIDs: Set(tipIDs), lastOpenedAt: now)
        let expanded = tipIDs + ["new"]
        #expect(schedule.automaticTip(progress, tipIDs: expanded, now: now.addingTimeInterval(86_399)) == nil)
        #expect(schedule.automaticTip(progress, tipIDs: expanded, now: now.addingTimeInterval(86_400)) == "new")
    }

    @Test func refresherFallsBackWhenTheCurrentTipWasRemoved() {
        let progress = SidebarTipsProgress(currentTipID: "gone", seenTipIDs: Set(tipIDs), lastOpenedAt: now)
        #expect(schedule.automaticTip(progress, tipIDs: tipIDs, now: now.addingTimeInterval(7 * 86_400)) == "a")
    }

    @Test func manualBrowsingWrapsAfterAllTipsHaveBeenSeen() {
        let progress = SidebarTipsProgress(currentTipID: "c", seenTipIDs: Set(tipIDs))
        #expect(schedule.opened(progress, tipIDs: tipIDs, now: now).currentTipID == "a")
    }

    @Test func removedTipsFallBackAndLegacyHistoryStillSuppressesToday() {
        let progress = SidebarTipsProgress(currentTipID: "gone", seenTipIDs: ["a"], lastOpenedDay: schedule.dayKey(for: now))
        #expect(schedule.opened(progress, tipIDs: tipIDs, now: now).currentTipID == "b")
        #expect(schedule.automaticTip(progress, tipIDs: tipIDs, now: now) == nil)
        #expect(schedule.automaticTip(progress, tipIDs: tipIDs, now: now.addingTimeInterval(86_400)) == "b")
    }

    @Test func automaticSelectionOnlyMarksTheChosenTipSeen() {
        let progress = SidebarTipsProgress(currentTipID: "b", seenTipIDs: ["b"])
        let chosen = schedule.automaticTip(progress, tipIDs: tipIDs, now: now)
        let opened = schedule.opened(progress, tipIDs: tipIDs, now: now, preferredTipID: chosen)
        #expect(opened.currentTipID == "a")
        #expect(opened.seenTipIDs == ["a", "b"])
    }

    @Test func dayKeyUsesTheGivenCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Pacific/Auckland"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 23, minute: 59)))
        #expect(schedule.dayKey(for: date, calendar: calendar) == "2026-01-05")
    }
}
