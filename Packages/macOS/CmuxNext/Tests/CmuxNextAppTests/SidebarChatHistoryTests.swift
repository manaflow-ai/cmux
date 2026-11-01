import AppKit
import CmuxNextActions
@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// hq#2569 #6: with `sidebar.sessionTree` on, chats stay in the sidebar after their workspace
/// closes: a Pinned block above the workspaces and a calm Earlier block under them, one page at a
/// time, built from the chat index's metadata only. A row resumes its chat; its menu pins it.
@MainActor @Suite(.serialized) struct SidebarChatHistoryTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// `count` chats, newest first (`c0` newest).
    private static func chats(_ count: Int) -> [SidebarHistoryChat] {
        (0..<count).map {
            SidebarHistoryChat(id: "c\($0)", title: "chat \($0)", updatedAt: start.addingTimeInterval(-Double($0) * 60),
                               harness: $0.isMultiple(of: 2) ? "codex" : "claude-code")
        }
    }

    private static func make(_ index: [SidebarHistoryChat], live: Set<String> = [], pinned: [String] = [], limit: Int = 3,
                             folded: Bool = false) -> SidebarChatHistoryState {
        let byID = Dictionary(uniqueKeysWithValues: index.map { ($0.id, $0) })
        return SidebarChatHistoryState.make(newest: index, chat: { byID[$0] }, live: live, pinned: pinned, limit: limit, folded: folded)
    }

    // MARK: State

    @Test func earlierListsOnePageOfTheChatsNoWorkspaceShowsAndPinsInPinOrder() {
        let state = Self.make(Self.chats(10), live: ["c0", "c2"], pinned: ["c5", "c1", "gone"])
        #expect(state.pinned.map(\.id) == ["c5", "c1"]) // a pinned chat the index no longer has is not shown
        #expect(state.earlier.map(\.id) == ["c3", "c4", "c6"]) // live and pinned chats are left out
        #expect(state.hasEarlier)
        #expect(state.hasMore)
    }

    @Test func theLastPageHasNoShowMoreAndAnEmptyIndexNoEarlier() {
        let last = Self.make(Self.chats(4), live: ["c0"], limit: 3)
        #expect(last.earlier.map(\.id) == ["c1", "c2", "c3"])
        #expect(!last.hasMore)
        let none = Self.make([], pinned: ["c1"])
        #expect(!none.hasEarlier && none.pinned.isEmpty)
        #expect(Self.make(Self.chats(2), live: ["c0", "c1"]).hasEarlier == false)
    }

    @Test func foldedEarlierKeepsItsHeaderButListsNoRows() {
        let state = Self.make(Self.chats(10), folded: true)
        #expect(state.hasEarlier)
        #expect(state.earlier.isEmpty)
        #expect(!state.hasMore)
        #expect(state.earlierHeight(.standard) == SidebarLayoutMetrics.standard.sectionHeaderHeight)
    }

    /// Thousands of chats cost one page: the index is read lazily and only until the page and one
    /// more chat are found (no full list, no transcript).
    @Test func aPageReadsOnlyThePageAndOneMoreOfTheIndex() {
        var read = 0
        let index = Self.chats(5_000)
        let lazy = index.lazy.map { chat -> SidebarHistoryChat in
            read += 1
            return chat
        }
        let state = SidebarChatHistoryState.make(newest: lazy, chat: { _ in nil }, live: ["c1"], pinned: [],
                                                 limit: SidebarChatHistory.pageSize, folded: false)
        #expect(state.earlier.count == SidebarChatHistory.pageSize)
        #expect(read == SidebarChatHistory.pageSize + 2) // the page, the live chat skipped, one more for Show More
    }

    @Test func heightsAreAHeaderAndOneRowPerChatPlusShowMore() {
        let m = SidebarLayoutMetrics.standard
        let row = m.rowHeight + m.rowSpacing
        let state = Self.make(Self.chats(10), pinned: ["c9"])
        #expect(state.pinnedHeight(m) == m.sectionHeaderHeight + row)
        #expect(state.earlierHeight(m) == m.sectionHeaderHeight + 4 * row)
        #expect(SidebarChatHistoryState().pinnedHeight(m) == 0)
        #expect(SidebarChatHistoryState().earlierHeight(m) == 0)
    }

    // MARK: Layout

    private static let workspaces = [
        SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: [
            .workspace(SidebarWorkspace(id: WorkspaceID("a"), title: "a")),
            .workspace(SidebarWorkspace(id: WorkspaceID("b"), title: "b"))
        ])
    ]

    private static func layout(_ history: SidebarChatHistoryState?, filter: Set<WorkspaceID>? = nil) -> SidebarLayout {
        var options = SidebarLayoutOptions()
        options.sessionTree = SidebarSessionTreeState()
        options.chatHistory = history
        options.filterMatches = filter
        return SidebarLayout.make(sections: workspaces, metrics: .standard, options: options)
    }

    @Test func pinnedSitsAboveTheWorkspacesAndEarlierUnderThemInGapsNoRowHitTests() throws {
        let m = SidebarLayoutMetrics.standard
        let history = Self.make(Self.chats(10), pinned: ["c9"])
        let layout = Self.layout(history)
        let pinnedY = try #require(layout.pinnedChatsY)
        let earlierY = try #require(layout.earlierChatsY)
        let first = try #require(layout.rows.first { if case .workspace = $0.key { true } else { false } })
        let last = try #require(layout.rows.last { if case .workspace = $0.key { true } else { false } })
        #expect(pinnedY + history.pinnedHeight(m) <= first.y)
        #expect(earlierY >= last.maxY)
        #expect(layout.totalHeight >= earlierY + history.earlierHeight(m))
        for y in [pinnedY + 1, earlierY + 1, earlierY + history.earlierHeight(m) - 1] {
            #expect(layout.row(at: y) == nil)
        }
    }

    @Test func withoutHistoryOrWhileFilteringTheListDrawsAsBefore() {
        let plain = Self.layout(nil)
        #expect(plain.pinnedChatsY == nil && plain.earlierChatsY == nil)
        #expect(Self.layout(SidebarChatHistoryState()).totalHeight == plain.totalHeight)
        let filtered = Self.layout(Self.make(Self.chats(10), pinned: ["c1"]), filter: [WorkspaceID("a")])
        #expect(filtered.pinnedChatsY == nil && filtered.earlierChatsY == nil)
    }

    /// Chat history lives in gaps between rows, so its placement must participate in layout
    /// identity. Otherwise `SidebarView+Observation` can skip moving the pinned or Earlier block
    /// when the rows and their frames stay unchanged.
    @Test func layoutEqualityIncludesChatHistoryPlacement() {
        var before = Self.layout(nil)
        var after = before
        after.pinnedChatsY = 12
        after.earlierChatsY = 96
        #expect(before != after)
        before.pinnedChatsY = after.pinnedChatsY
        before.earlierChatsY = after.earlierChatsY
        #expect(before == after)
    }

    @Test func pinnedStillShowsWhenNoComputerListsARow() {
        var options = SidebarLayoutOptions()
        options.chatHistory = Self.make([], pinned: [])
        let empty: [SidebarSection] = []
        #expect(SidebarLayout.make(sections: empty, metrics: .standard, options: options).pinnedChatsY == nil)
        options.chatHistory = SidebarChatHistoryState(pinned: Self.chats(1))
        #expect(SidebarLayout.make(sections: empty, metrics: .standard, options: options).pinnedChatsY != nil)
    }

    // MARK: Pins, the fold and pages

    private static func defaults() throws -> UserDefaults {
        let suite = "SidebarChatHistoryTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    @Test func pinsAndTheFoldAreKeptAcrossLaunchesAndPagesAreNot() throws {
        let defaults = try Self.defaults()
        let history = SidebarChatHistory(defaults: defaults)
        history.setPinned("b", true)
        history.setPinned("a", true)
        history.setPinned("b", true) // already pinned: stays where it was
        history.toggleEarlier()
        history.showMore()
        #expect(history.limit == 2 * SidebarChatHistory.pageSize)
        let relaunched = SidebarChatHistory(defaults: defaults)
        #expect(relaunched.pinned == ["b", "a"])
        #expect(relaunched.earlierFolded)
        #expect(relaunched.limit == SidebarChatHistory.pageSize)
        relaunched.setPinned("b", false)
        #expect(SidebarChatHistory(defaults: defaults).pinned == ["a"])
    }

    // MARK: Rows

    @Test func earlierMakesRowsForThePageOnlyAndRowsOpenAndPin() throws {
        let history = SidebarChatHistory(defaults: try Self.defaults())
        var opened: [String] = []
        history.onOpen = { opened.append($0) }
        let view = SidebarChatHistoryView(part: .earlier)
        view.history = history
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        view.show(Self.make(Self.chats(50), limit: 3), metrics: .standard)
        view.layoutSubtreeIfNeeded()
        #expect(view.rows.map(\.titleText) == ["chat 0", "chat 1", "chat 2"])
        #expect(!view.more.isHidden)
        #expect(view.header.foldable)
        view.rows[1].onClick?()
        #expect(opened == ["c1"])
        // The row's menu is the registry's Pin or Unpin Chat on its chat, retitled for this chat.
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        SidebarChatHistoryFeed.bind(into: registry, history: history)
        let menu = try #require(view.rows[1].contextMenu())
        #expect(menu.items.map(\.title) == [Strings.chatHistoryPin])
        let run = try #require(menu.items.first.flatMap(ActionRegistry.menuRun(of:)))
        #expect(run.id == SidebarChatHistoryFeed.togglePinAction)
        #expect(run.target == ActionTargetRef(kind: .sidebarItem, id: "c1"))
        #expect(registry.perform(run.id, invocation: ActionInvocation(target: run.target)))
        #expect(history.pinned == ["c1"])
        #expect(view.rows[1].contextMenu()?.items.map(\.title) == [Strings.chatHistoryUnpin])
        view.more.onClick?()
        #expect(history.limit == 2 * SidebarChatHistory.pageSize)
        view.header.onClick?()
        #expect(history.earlierFolded)
    }

    @Test func foldedEarlierHidesItsRowsAndShowMore() {
        let view = SidebarChatHistoryView(part: .earlier)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        view.show(Self.make(Self.chats(5), limit: 3), metrics: .standard)
        view.show(Self.make(Self.chats(5), limit: 3, folded: true), metrics: .standard)
        view.layoutSubtreeIfNeeded()
        #expect(view.rows.isEmpty)
        #expect(view.more.isHidden)
        #expect(view.header.folded)
    }

    @Test func pinnedRowsAreNotQuietAndItsHeaderDoesNotFold() {
        let view = SidebarChatHistoryView(part: .pinned)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        view.show(SidebarChatHistoryState(pinned: Self.chats(2)), metrics: .standard)
        #expect(view.rows.map(\.titleText) == ["chat 0", "chat 1"])
        #expect(view.more.isHidden)
        #expect(!view.header.foldable)
        #expect(view.header.titleText == Strings.pinned)
    }

    // MARK: The feed

    @Test func aLaneNamesTheIndexedChatItsSessionContinues() {
        func lane(_ family: String?, _ agentSession: String?) -> AgentActivityLane? {
            var summary: [String: Any] = ["sessionId": "s1", "lane": ["state": "idle"]]
            summary["family"] = family
            summary["agentSessionId"] = agentSession
            return AgentActivityLane.of(summary: summary)
        }
        #expect(lane("claude", "abc")?.chat == "claude-code:abc")
        #expect(lane("codex", "xyz")?.chat == "codex:xyz")
        #expect(lane("gemini", "abc")?.chat == nil)
        #expect(lane("claude", nil)?.chat == nil)
    }

    /// acpmux's window holds no child chat (`topLevel`); the history names an untitled chat by its
    /// folder, else its harness, and leaves out a chat an open workspace shows until acpmux's next
    /// window excludes it too.
    @Test func theFeedListsTheWindowAndNamesUntitledOnes() {
        let json: [[String: Any]] = [
            ["key": "claude-code:1", "sessionId": "1", "harness": "claude-code", "title": "Fix the build", "updatedMs": 3_000],
            ["key": "codex:2", "sessionId": "2", "harness": "codex", "cwd": "/Users/me/cmux", "updatedMs": 2_000],
            ["key": "claude-code:4", "sessionId": "4", "harness": "claude-code", "updatedMs": 500]
        ]
        let rows = json.compactMap(AcpmuxChat.init(json:))
        let inputs = SidebarChatHistoryFeed.Inputs(live: ["claude-code:1"], pinned: [], limit: 10, folded: false)
        #expect(inputs.earlierSpec.topLevel)
        #expect(inputs.earlierSpec.exclude == ["claude-code:1"])
        let state = SidebarChatHistoryFeed.state(earlier: rows, pinned: [], inputs: inputs)
        #expect(state.earlier.map(\.id) == ["codex:2", "claude-code:4"])
        #expect(state.earlier.map(\.title) == ["cmux", "claude-code"])
        #expect(state.earlier.map(\.harness) == ["codex", "claude-code"])
    }

    @Test func historyRowsCarryHarnessMarksAndStableFallbackColoursAcrossReuse() throws {
        let view = SidebarChatHistoryView(part: .earlier)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        let codex = SidebarHistoryChat(id: "codex:1", title: "same title", updatedAt: Self.start, harness: "codex")
        let unknown = SidebarHistoryChat(id: "acme:1", title: "same title", updatedAt: Self.start, harness: "acme-agent")
        view.show(SidebarChatHistoryState(earlier: [codex]), metrics: .standard)
        view.layoutSubtreeIfNeeded()
        let row = try #require(view.rows.first)
        #expect(row.harness == "codex")
        #expect(row.harnessMarkColor == nil)
        #expect(row.titleText == "same title")
        view.show(SidebarChatHistoryState(earlier: [unknown]), metrics: .standard)
        view.layoutSubtreeIfNeeded()
        #expect(row.harness == "acme-agent")
        #expect(row.harnessMarkColor == GroupColor.unset(id: "acme-agent"))
        #expect(row.harnessMarkColor != nil)
    }
}
