@testable import CmuxNextFeed
import Foundation
import Testing

@MainActor
struct FeedGroupingTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    @Test func inboxGroupsNeedsYouTodayAndEarlier() {
        let (model, _) = startedFeed()
        let groups = FeedInboxGroups(items: model.visibleItems, now: feedTestNow, calendar: utc)
        #expect(groups.needsYou.map(\.head.id).sorted() == model.visibleItems.filter(\.isOpenRequest).map(\.id).sorted())
        #expect(groups.needsYou.allSatisfy { $0.members.count == 1 }, "each open request keeps its own row")
        #expect(groups.today.map(\.head.id) == ["fi_status_run", "fi_build_done", "fi_github_review", "fi_osc9"])
        #expect(groups.earlier.map(\.head.id) == ["fi_answered_push", "fi_build_prev", "fi_expired_npm"])
        let ciThread = groups.earlier.first { $0.head.id == "fi_build_prev" }
        #expect(ciThread?.members.map(\.id) == ["fi_build_prev", "fi_build_old"], "a thread collapses under its newest item")
    }

    @Test func everyActiveItemLandsInExactlyOneGroup() {
        let (model, _) = startedFeed()
        let groups = FeedInboxGroups(items: model.visibleItems, now: feedTestNow, calendar: utc)
        let grouped = groups.all.flatMap(\.members).map(\.id)
        #expect(grouped.count == Set(grouped).count)
        #expect(Set(grouped) == Set(model.visibleItems.map(\.id)))
    }

    @Test func archivedAndSnoozedItemsLeaveTheGroups() {
        let (model, source) = startedFeed(echo: false)
        model.archive(["fi_status_run"])
        model.snooze(["fi_github_review"], for: 3_600)
        source.deliverHeld()
        let groups = FeedInboxGroups(items: model.visibleItems, now: feedTestNow, calendar: utc)
        let ids = Set(groups.all.flatMap(\.members).map(\.id))
        #expect(!ids.contains("fi_status_run"))
        #expect(!ids.contains("fi_github_review"))
        let later = FeedInboxGroups(items: model.visibleItems, now: feedTestNow.addingTimeInterval(7_200), calendar: utc)
        #expect(later.all.contains { $0.head.id == "fi_github_review" }, "a snooze ends at its deadline")
    }

    @Test func listPinsOpenRequestsByPriorityThenNewest() {
        let (model, _) = startedFeed()
        let sections = model.listSections
        #expect(sections.requests.allSatisfy { $0.isOpenRequest })
        #expect(sections.rest.allSatisfy { !$0.isOpenRequest })
        #expect(sections.requests.first?.id == "fi_claude_rm_build")
        #expect(sections.requests.last?.id == "fi_claude_plan", "review defaults to normal priority")
    }

    @Test func menubarShowsOpenRequestsOnly() {
        let (model, _) = startedFeed(echo: false)
        let before = model.menubarItems
        #expect(!before.isEmpty)
        #expect(before.allSatisfy { $0.isOpenRequest })
        #expect(before.count == model.visibleItems.filter(\.isOpenRequest).count)
        model.answer("fi_claude_rm_build", .approve(.init(.allow)))
        #expect(!model.menubarItems.contains { $0.id == "fi_claude_rm_build" }, "a pending answer leaves the menu bar at once")
    }

    @Test func menubarIsEmptyWhenNothingIsOpen() {
        let notice = FeedItem(id: "fi_n", title: "Done", poster: FeedPoster(kind: .system, label: "status run"), createdAt: feedTestNow)
        #expect(FeedOrder.menubar([notice], now: feedTestNow).isEmpty)
    }

    @Test func countsAreOpenRequestsPlusUnreadNotices() {
        let (model, _) = startedFeed()
        let counts = model.counts
        #expect(counts.openRequests == 8)
        #expect(counts.unreadNotices == 2)
        #expect(counts.badge == 10)
    }
}
