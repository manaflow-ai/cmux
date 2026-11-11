import AppKit
import CmuxNextActions
@testable import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextAgentPane
@testable import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextSettings
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Foundation
import Testing
import WebKit

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

    /// The history of `index` as acpmux's Earlier window answers it: `more` (acpmux's `hasMore`) is
    /// whether more chats than the page pass the window's exclusions (acpmux's own cases:
    /// `a_window_says_whether_more_chats_pass_past_its_page` in cmux-tui/crates/acpmux/tests/chats_window.rs).
    private static func make(_ index: [SidebarHistoryChat], live: Set<String> = [], pinned: [String] = [], limit: Int = 3,
                             folded: Bool = false) -> SidebarChatHistoryState {
        let byID = Dictionary(uniqueKeysWithValues: index.map { ($0.id, $0) })
        let skipped = live.union(pinned)
        let more = index.filter { !skipped.contains($0.id) }.count > limit
        return SidebarChatHistoryState.make(newest: index, chat: { byID[$0] }, live: live, pinned: pinned, limit: limit, folded: folded,
                                            more: more)
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

    /// Thousands of chats cost one page: the window is read lazily and only until the page is full;
    /// Show More is acpmux's `hasMore`, so no chat past the page is read to find it.
    @Test func aPageReadsOnlyThePage() {
        var read = 0
        let index = Self.chats(5_000)
        let lazy = index.lazy.map { chat -> SidebarHistoryChat in
            read += 1
            return chat
        }
        let state = SidebarChatHistoryState.make(newest: lazy, chat: { _ in nil }, live: ["c1"], pinned: [],
                                                 limit: SidebarChatHistory.pageSize, folded: false, more: true)
        #expect(state.earlier.count == SidebarChatHistory.pageSize)
        #expect(state.hasMore)
        #expect(read == SidebarChatHistory.pageSize + 1) // the page and the live chat skipped
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
        return try #require(UserDefaults(testSuiteName: suite))
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

    // MARK: Rows (the React block, webviews/src/pages/sidebar-chats, through its host)

    /// A block host with no page (the page's own tests are webviews `sidebar-chats-page.test.tsx`).
    private static func host(_ part: SidebarChatHistoryHost.Part, history: SidebarChatHistory) -> SidebarChatHistoryHost {
        let host = SidebarChatHistoryHost(part: part, makePage: { _ in nil })
        host.history = history
        return host
    }

    /// The person's click in the page view, as the router records it; each call spends its own.
    private static func click(_ at: TimeInterval) -> PageCallContext {
        PageCallContext(page: PageDescriptor.sidebarChats.id, userGesture: true, gestureEvent: at)
    }

    @Test func earlierSendsThePageOnlyAndItsRowsOpenFoldShowMoreAndPin() async throws {
        let history = SidebarChatHistory(defaults: try Self.defaults())
        var opened: [String] = []
        history.onOpen = { opened.append($0) }
        let host = Self.host(.earlier, history: history)
        host.show(Self.make(Self.chats(50), limit: 3), metrics: .standard, width: 240)
        let block = try #require(host.provider.block)
        #expect(block.rows.map(\.title) == ["chat 0", "chat 1", "chat 2"])
        #expect(block.tail == .more)
        #expect(!block.folded)
        #expect(block.height == Double(Self.make(Self.chats(50), limit: 3).earlierHeight(.standard)), "the page draws the gap the layout keeps")
        let op = { (name: String) in SidebarChatHistoryProvider.prefix + name }
        _ = try await host.provider.call(op("open"), params: .object(["revision": .number(1), "chat": .string("c1")]), context: Self.click(1))
        #expect(opened == ["c1"])
        // The row's menu is the registry's Pin or Unpin Chat on its chat, retitled for this chat.
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        SidebarChatHistoryFeed.bind(into: registry, history: history)
        let menu = try #require(host.contextMenu(for: "c1"))
        #expect(menu.items.map(\.title) == [Strings.chatHistoryPin])
        let run = try #require(menu.items.first.flatMap(ActionRegistry.menuRun(of:)))
        #expect(run.id == SidebarChatHistoryFeed.togglePinAction)
        #expect(run.target == ActionTargetRef(kind: .sidebarItem, id: "c1"))
        #expect(registry.perform(run.id, invocation: ActionInvocation(target: run.target)))
        #expect(history.pinned == ["c1"])
        #expect(host.contextMenu(for: "c1")?.items.map(\.title) == [Strings.chatHistoryUnpin])
        _ = try await host.provider.call(op("more"), params: .object(["revision": .number(1)]), context: Self.click(2))
        #expect(history.limit == 2 * SidebarChatHistory.pageSize)
        _ = try await host.provider.call(op("fold"), params: .object(["revision": .number(1)]), context: Self.click(3))
        #expect(history.earlierFolded)
    }

    /// The page acts only on the person's own click, once per click, and only on a chat it was shown.
    @Test func pageCallsNeedAFreshClickAndAShownChat() async throws {
        let history = SidebarChatHistory(defaults: try Self.defaults())
        var opened: [String] = []
        history.onOpen = { opened.append($0) }
        let host = Self.host(.earlier, history: history)
        host.show(Self.make(Self.chats(5), limit: 3), metrics: .standard, width: 240)
        let open = SidebarChatHistoryProvider.prefix + "open"
        let params = { (chat: String) in CmuxNextSettings.JSONValue.object(["revision": .number(1), "chat": .string(chat)]) }
        await #expect(throws: PageError.self) {
            _ = try await host.provider.call(open, params: params("c0"), context: PageCallContext(page: PageDescriptor.sidebarChats.id))
        }
        await #expect(throws: PageError.self) { _ = try await host.provider.call(open, params: params("c4"), context: Self.click(1)) }
        _ = try await host.provider.call(open, params: params("c0"), context: Self.click(2))
        await #expect(throws: PageError.self) { _ = try await host.provider.call(open, params: params("c1"), context: Self.click(2)) }
        #expect(opened == ["c0"], "no script-only open, no chat outside the page, one open per click")
        // Pinned has no fold and no Show More.
        let pinned = Self.host(.pinned, history: history)
        pinned.show(SidebarChatHistoryState(pinned: Self.chats(2)), metrics: .standard, width: 240)
        await #expect(throws: PageError.self) {
            _ = try await pinned.provider.call(SidebarChatHistoryProvider.prefix + "fold", params: .object([:]), context: Self.click(3))
        }
        #expect(!history.earlierFolded)
    }

    /// cmux#40314 F1 (manaflow-ai/cmux#37809): with VoiceOver running, a VoiceOver press (AXPress) on a row, Earlier's
    /// fold or Show More acts with no mouse event before it, as the deleted native rows' `accessibilityPerformPress()`
    /// did. WebKit makes the press a trusted click, whose post in ``PageAccessibilityPress``'s world backs the call;
    /// a click page script makes is untrusted, posts nothing and is refused.
    @Test func voiceOverPressesOpenFoldAndShowMoreWithNoMouseEventAndScriptClicksDoNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-chats-ax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<!doctype html><title>Chats</title><button id=b>Open</button>".utf8).write(to: root.appendingPathComponent("index.html"))
        let history = SidebarChatHistory(defaults: try Self.defaults())
        var opened: [String] = []
        history.onOpen = { opened.append($0) }
        let host = SidebarChatHistoryHost(part: .earlier) { provider in
            PageWebView(descriptor: .sidebarChats, root: root, testRoot: true,
                        routes: [PageRoute(prefix: SidebarChatHistoryProvider.prefix, provider: provider)], chromium: nil)
        }
        host.history = history
        host.show(Self.make(Self.chats(5), limit: 3), metrics: .standard, width: 240)
        let page = try #require(host.page)
        defer { page.close() }
        page.webView.isVoiceOverRunning = { true }
        await page.waitUntilLoaded()
        #expect(page.webView.lastUserEventUptime == nil, "no key or mouse event reached the page view")

        var id = 0.0
        func call(_ name: String, _ params: [String: CmuxNextSettings.JSONValue] = [:]) async -> CmuxNextSettings.JSONValue {
            id += 1
            var all = params
            all["revision"] = .number(1)
            return await page.router.handle(["t": "call", "id": .number(id), "op": .string(SidebarChatHistoryProvider.prefix + name),
                                             "params": .object(all)])
        }
        /// The press world's post, as its listener makes it for WebKit's trusted AXPress click.
        func press() async throws {
            _ = try await page.webView.callAsyncJavaScript(
                "window.webkit.messageHandlers.\(PageAccessibilityPress.handlerName).postMessage(1); return true;",
                arguments: [:], in: nil, contentWorld: PageAccessibilityPress.world)
        }
        /// Page script's own click (untrusted), then a round trip in the press world so any post it made has arrived.
        func scriptClick() async throws {
            _ = try await page.webView.callAsyncJavaScript("document.getElementById('b').click(); return true;",
                                                          arguments: [:], in: nil, contentWorld: .page)
            _ = try await page.webView.callAsyncJavaScript("return true;", arguments: [:], in: nil, contentWorld: PageAccessibilityPress.world)
        }

        try await scriptClick()
        #expect(await call("open", ["chat": .string("c0")])["t"] == "err", "a script click opens nothing")

        try await press()
        #expect(await call("open", ["chat": .string("c0")])["t"] == "ok")
        #expect(opened == ["c0"])
        #expect(await call("open", ["chat": .string("c1")])["t"] == "err", "one press, one action")

        // Uptimes of two presses in a row may tie at the clock's grain; each press is its own moment.
        try await Task.sleep(for: .milliseconds(5))
        try await press()
        #expect(await call("more")["t"] == "ok")
        #expect(history.limit == 2 * SidebarChatHistory.pageSize)

        try await Task.sleep(for: .milliseconds(5))
        try await press()
        #expect(await call("fold")["t"] == "ok")
        #expect(history.earlierFolded)

        try await Task.sleep(for: .milliseconds(5))
        try await scriptClick()
        #expect(await call("fold")["t"] == "err", "a script click folds nothing")
        #expect(history.earlierFolded)
        #expect(opened == ["c0"])
    }

    @Test func aBlockIsSentOnlyWhenItChangesAndTheReadyReportShowsThePage() async throws {
        let host = Self.host(.earlier, history: SidebarChatHistory(defaults: try Self.defaults()))
        let state = Self.make(Self.chats(5), limit: 3)
        host.show(state, metrics: .standard, width: 240)
        host.show(state, metrics: .standard, width: 240)
        #expect(host.provider.revision == 1)
        host.show(Self.make(Self.chats(5), limit: 4), metrics: .standard, width: 240)
        #expect(host.provider.revision == 2)
        _ = try await host.provider.call(SidebarChatHistoryProvider.prefix + "ready",
                                         params: .object(["revision": .number(2), "height": .number(150)]),
                                         context: PageCallContext(page: PageDescriptor.sidebarChats.id))
        #expect(host.drawn?.revision == 2)
        #expect(host.drawn?.height == 150)
    }

    @Test func foldedEarlierSendsNoRowsAndNoShowMore() throws {
        let host = Self.host(.earlier, history: SidebarChatHistory(defaults: try Self.defaults()))
        host.show(Self.make(Self.chats(5), limit: 3, folded: true), metrics: .standard, width: 240)
        let block = try #require(host.provider.block)
        #expect(block.rows.isEmpty)
        #expect(block.tail == nil)
        #expect(block.folded)
        #expect(block.height == Double(SidebarLayoutMetrics.standard.sectionHeaderHeight))
    }

    @Test func pinnedDoesNotFoldAndHasNoTail() throws {
        let host = Self.host(.pinned, history: SidebarChatHistory(defaults: try Self.defaults()))
        host.show(SidebarChatHistoryState(pinned: Self.chats(2)), metrics: .standard, width: 240)
        let block = try #require(host.provider.block)
        #expect(block.rows.map(\.title) == ["chat 0", "chat 1"])
        #expect(block.tail == nil)
        #expect(!block.folded)
        #expect(block.part == .pinned)
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
        let state = SidebarChatHistoryFeed.state(earlier: rows, more: false, pinned: [], inputs: inputs)
        #expect(state.earlier.map(\.id) == ["codex:2", "claude-code:4"])
        #expect(state.earlier.map(\.title) == ["cmux", "claude-code"])
        #expect(state.earlier.map(\.harness) == ["codex", "claude-code"])
    }

    /// Rust migration A7: Earlier asks acpmux for the page only and shows Show More when acpmux says more
    /// chats wait (`hasMore`), never by asking for one more row and cutting it.
    @Test func showMoreIsAcpmuxsHasMore() throws {
        let inputs = SidebarChatHistoryFeed.Inputs(live: [], pinned: [], limit: 2, folded: false)
        #expect(inputs.earlierSpec.limit == 2, "the page, not one more row")
        #expect(SidebarChatHistoryFeed.Inputs(live: [], pinned: [], limit: 2, folded: true).earlierSpec.limit == 1)
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        windows.open(inputs.earlierSpec)
        let generation = try #require(sent.last?["gen"] as? UInt64)
        let rows: [[String: Any]] = [
            ["key": "codex:1", "sessionId": "1", "harness": "codex", "title": "one", "updatedMs": 2_000],
            ["key": "codex:2", "sessionId": "2", "harness": "codex", "title": "two", "updatedMs": 1_000]
        ]
        let full: [String: Any] = ["window": SidebarChatHistoryFeed.earlierWindow, "gen": NSNumber(value: generation),
                                   "revision": NSNumber(value: 1), "full": true, "keys": ["codex:1", "codex:2"], "rows": rows,
                                   "hasMore": true]
        windows.apply(try #require(AcpmuxChatWindows.Update(params: full)))
        let earlier = windows.window(SidebarChatHistoryFeed.earlierWindow)
        #expect(earlier.hasMore)
        let state = SidebarChatHistoryFeed.state(earlier: earlier.rows, more: earlier.hasMore, pinned: [], inputs: inputs)
        #expect(state.earlier.map(\.id) == ["codex:1", "codex:2"])
        #expect(state.hasMore, "acpmux says more chats wait")
        var last = full
        last["revision"] = NSNumber(value: 2)
        last["full"] = false
        last["rows"] = [[String: Any]]()
        last["hasMore"] = false
        windows.apply(try #require(AcpmuxChatWindows.Update(params: last)))
        #expect(!earlier.hasMore, "a diff that only changes hasMore reaches the window")
        #expect(!SidebarChatHistoryFeed.state(earlier: earlier.rows, more: earlier.hasMore, pinned: [], inputs: inputs).hasMore,
                "the last page has no Show More")
    }

    /// Leo, 2026-11-05 (ask-26245544ff): "i cant see any chats" after a restart into a new nightly. acpmux took 42 s
    /// under load to start its chat index and answered Earlier `ready: false` until then; the history drew nothing, which
    /// reads as every chat gone. Until acpmux first sends Earlier's rows it keeps its header and a Loading row.
    @Test func earlierSaysLoadingUntilAcpmuxFirstSendsItsRows() async throws {
        let inputs = SidebarChatHistoryFeed.Inputs(live: [], pinned: [], limit: 3, folded: false)
        let windows = AcpmuxChatWindows()
        var sent: [[String: any Sendable]] = []
        windows.connected { (_: String, params: [String: any Sendable]) in sent.append(params) }
        windows.open(inputs.earlierSpec)
        let generation = try #require(sent.last?["gen"] as? UInt64)
        windows.requestNotReady(SidebarChatHistoryFeed.earlierWindow, generation: generation)
        let earlier = windows.window(SidebarChatHistoryFeed.earlierWindow)
        #expect(!earlier.hasAnswered)
        let waiting = SidebarChatHistoryFeed.state(earlier: earlier.rows, more: earlier.hasMore, pinned: [], inputs: inputs,
                                                   loading: !earlier.hasAnswered)
        #expect(waiting.hasEarlier && waiting.showsLoading, "an index still starting is not an empty history")
        let m = SidebarLayoutMetrics.standard
        #expect(waiting.earlierHeight(m) == m.sectionHeaderHeight + m.rowHeight + m.rowSpacing)
        let history = SidebarChatHistory(defaults: try Self.defaults())
        let host = Self.host(.earlier, history: history)
        host.show(waiting, metrics: m, width: 240)
        #expect(host.provider.block?.tail == .loading)
        #expect(host.provider.block?.height == Double(waiting.earlierHeight(m)))
        let limit = history.limit
        await #expect(throws: Never.self) {
            _ = try await host.provider.call(SidebarChatHistoryProvider.prefix + "more", params: .object([:]), context: Self.click(1))
        }
        #expect(history.limit == limit, "the Loading row asks for no page")

        let full: [String: Any] = ["window": SidebarChatHistoryFeed.earlierWindow, "gen": NSNumber(value: generation),
                                   "revision": NSNumber(value: 1), "full": true, "keys": [String](), "rows": [[String: Any]](),
                                   "hasMore": false]
        windows.apply(try #require(AcpmuxChatWindows.Update(params: full)))
        #expect(earlier.hasAnswered)
        let empty = SidebarChatHistoryFeed.state(earlier: earlier.rows, more: earlier.hasMore, pinned: [], inputs: inputs,
                                                 loading: !earlier.hasAnswered)
        #expect(!empty.hasEarlier && !empty.showsLoading, "an answered empty index has no Earlier")
        #expect(!Self.make(Self.chats(2), folded: true).showsLoading)
        #expect(!SidebarChatHistoryState(earlierFolded: true, loading: true).showsLoading, "folded Earlier keeps only its header")
    }

    @Test func historyRowsCarryHarnessMarksAndStableFallbackColours() throws {
        let host = Self.host(.earlier, history: SidebarChatHistory(defaults: try Self.defaults()))
        let codex = SidebarHistoryChat(id: "codex:1", title: "same title", updatedAt: Self.start, harness: "codex")
        let unknown = SidebarHistoryChat(id: "acme:1", title: "same title", updatedAt: Self.start, harness: "acme-agent")
        host.show(SidebarChatHistoryState(earlier: [codex]), metrics: .standard, width: 240)
        let row = try #require(host.provider.block?.rows.first)
        #expect(row.harness == "codex")
        #expect(row.markColor == nil)
        #expect(row.title == "same title")
        host.show(SidebarChatHistoryState(earlier: [unknown]), metrics: .standard, width: 240)
        let other = try #require(host.provider.block?.rows.first)
        #expect(other.harness == "acme-agent")
        let colour = host.performWithTheme { SidebarChatHistoryBlock.css(GroupColor.unset(id: "acme-agent").markColor) }
        #expect(other.markColor != nil)
        #expect(other.markColor == colour)
    }
}
