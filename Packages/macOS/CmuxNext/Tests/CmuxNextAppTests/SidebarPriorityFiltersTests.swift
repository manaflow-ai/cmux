import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextSidebar
import Foundation
import Testing

/// The Codex app's priority view in the Priority view: the filter chips and their counts
/// (`sidebar.priorityView.filters`), idle chats left out (`sidebar.priorityView.showIdle` off),
/// Mark All as Read, and a drag under a filter keeping the hidden rows' places. With the keys at
/// their defaults the panel is today's.
@MainActor
struct SidebarPriorityFiltersTests {
    @MainActor final class Keys {
        var filters = false
        var showIdle = true
        var statusWords = false
        var actions: [SidebarPriorityAction] = []
    }

    private static func lane(_ id: String, _ state: String, unread: Bool = false, ago: TimeInterval) throws -> AgentActivityLane {
        try #require(AgentActivityLane.of(summary: [
            "sessionId": id, "unread": unread,
            "lane": ["state": state, "since": NSNumber(value: (Date().timeIntervalSince1970 - ago) * 1000)],
        ]))
    }

    /// Two waiting, two unread (one failed), two running and one idle chat.
    private static func feed(_ keys: Keys, lanes: [String: AgentActivityLane]? = nil,
                             marked: @escaping @MainActor (SidebarPriorityAction) -> Void = { _ in })
        throws -> (SidebarPriorityFeed, AgentPriorityChats) {
        let store = AgentLaneStore()
        store.lanes = try lanes ?? [
            "ask-1": lane("ask-1", "input", ago: 10), "ask-2": lane("ask-2", "input", ago: 20),
            "done-1": lane("done-1", "idle", unread: true, ago: 30), "fail-1": lane("fail-1", "failed", unread: true, ago: 40),
            "run-1": lane("run-1", "working", ago: 50), "run-2": lane("run-2", "working", ago: 60),
            "quiet": lane("quiet", "idle", ago: 70),
        ]
        let chats = AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [store], checksFailing: { _ in false }) { _, _ in }
        let feed = SidebarPriorityFeed(settings: .init(enabled: { true }, shown: { true }, filters: { keys.filters },
                                                       showIdle: { keys.showIdle }, statusWords: { keys.statusWords }),
                                       hooks: .init(shortcut: { nil }, open: { _ in }, rowAction: marked, toggleShown: {}), chats: chats)
        return (feed, chats)
    }

    @Test func defaultKeysDrawTodaysPanel() throws {
        let (feed, _) = try Self.feed(Keys())
        let panel = try #require(feed.panel())
        #expect(panel.filters == nil && !panel.statusWords)
        #expect(panel.entries.map(\.id) == ["ask-1", "ask-2", "done-1", "fail-1", "run-1", "run-2", "quiet"])
        #expect(panel.attentionCount == 4)
    }

    @Test func filtersCountEveryRowAndShowThePickedOnes() throws {
        let keys = Keys()
        keys.filters = true
        keys.showIdle = false
        keys.statusWords = true
        let (feed, chats) = try Self.feed(keys)
        var panel = try #require(feed.panel())
        let bar = try #require(panel.filters)
        #expect(panel.statusWords)
        #expect(panel.entries.map(\.id) == ["ask-1", "ask-2", "done-1", "fail-1", "run-1", "run-2"], "idle chats leave the list")
        #expect(bar.selected == .all)
        let counts: [Int] = SidebarPriorityFilter.allCases.map { bar.count($0) }
        #expect(counts == [6, 2, 2, 2])
        #expect(bar.markable == 2)
        feed.perform(.setFilter(.unread))
        panel = try #require(feed.panel())
        #expect(panel.entries.map(\.id) == ["done-1", "fail-1"])
        #expect(panel.filters?.count(SidebarPriorityFilter.all) == 6, "counts stay over every row")
        #expect(panel.attentionCount == 4, "the bell and the folded count include the rows the filter hides")
        feed.perform(.setFilter(.running))
        #expect(feed.panel()?.entries.map(\.id) == ["run-1", "run-2"])
        feed.perform(.setFilter(.waiting))
        #expect(feed.panel()?.entries.map(\.id) == ["ask-1", "ask-2"])
        #expect(chats.marks.state.filter == .waiting, "the pick is kept with the other marks")
    }

    @Test func aPinnedIdleChatStaysWithoutIdleChats() throws {
        let keys = Keys()
        keys.showIdle = false
        let (feed, chats) = try Self.feed(keys)
        #expect(chats.togglePin("quiet"))
        #expect(feed.panel()?.entries.map(\.id).contains("quiet") == true)
    }

    @Test func markAllReadMarksEveryUnseenResultTheFilterHidesToo() throws {
        let keys = Keys()
        keys.filters = true
        let marked = Keys()
        let (feed, _) = try Self.feed(keys) { marked.actions.append($0) }
        feed.perform(.setFilter(.running))
        _ = feed.panel()
        feed.perform(.markAllRead)
        #expect(marked.actions == [.markRead("done-1"), .markRead("fail-1")])
    }

    @Test func aDragUnderAFilterKeepsTheHiddenRowsPlaces() {
        let all = ["ask-1", "ask-2", "done-1", "fail-1", "run-1", "run-2"]
        #expect(SidebarPriorityFeed.merged(["run-2", "run-1"], into: all) == ["ask-1", "ask-2", "done-1", "fail-1", "run-2", "run-1"])
        #expect(SidebarPriorityFeed.merged(all.reversed(), into: all) == all.reversed(), "under All the order is the whole list")
    }

    /// All shows [a, b, c] (a and c waiting, c dragged to the bottom, b an unseen result). Under
    /// Waiting the person drags c above a: the whole list becomes [c, b, a], b keeping its slot.
    @Test func aDragUnderAFilterGivesTheMergedFeedOrder() throws {
        let keys = Keys()
        keys.filters = true
        let (feed, chats) = try Self.feed(keys, lanes: [
            "a": Self.lane("a", "input", ago: 10), "c": Self.lane("c", "input", ago: 20),
            "b": Self.lane("b", "idle", unread: true, ago: 30),
        ])
        #expect(feed.panel()?.entries.map(\.id) == ["a", "c", "b"])
        feed.perform(.place("c", order: ["a", "b", "c"]))
        #expect(feed.panel()?.entries.map(\.id) == ["a", "b", "c"])
        feed.perform(.setFilter(.waiting))
        #expect(feed.panel()?.entries.map(\.id) == ["a", "c"])
        feed.perform(.place("c", order: ["c", "a"]))
        #expect(feed.panel()?.entries.map(\.id) == ["c", "a"])
        feed.perform(.setFilter(.all))
        #expect(feed.panel()?.entries.map(\.id) == ["c", "b", "a"], "b keeps the slot it held")
        #expect(chats.marks.state.placed == ["c": 0, "a": 2])
    }

    @Test func filtersPickTheirTiers() {
        func entry(_ state: SidebarPriorityEntry.State) -> SidebarPriorityEntry { SidebarPriorityEntry(id: "x", title: "x", state: state) }
        #expect(SidebarPriorityFilter.waiting.includes(entry(.needsYou)))
        #expect(SidebarPriorityFilter.unread.includes(entry(.done)) && SidebarPriorityFilter.unread.includes(entry(.lost)))
        #expect(SidebarPriorityFilter.running.includes(entry(.working(since: nil))))
        #expect(!SidebarPriorityFilter.unread.includes(entry(.ciFailing)) && !SidebarPriorityFilter.running.includes(entry(.idle)))
        #expect(SidebarPriorityFilter.all.includes(entry(.idle)))
    }
}
