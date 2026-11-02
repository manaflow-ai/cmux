import CmuxMobileModel
import Foundation
import Observation
import Testing
@testable import CmuxMobileWorkspaces

// WorkspaceTabsSource is iOS-only: these run in the iOS simulator test pass.
#if os(iOS)
import CmuxMobileAgentChat
import CmuxTabsKit
import SwiftUI

/// The tab grid's list (verify/listperf, tabs lane): the source publishes
/// `tabs` only when a field the kit shows changes, and rebuilds only the
/// tabs whose inputs changed, so a busy Mac or a streaming chat does not
/// re-run the tabs screen and every card.
@MainActor @Suite(.serialized) struct WorkspaceTabsSourceListTests {
    static func source(_ store: AppStore) -> WorkspaceTabsSource {
        WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", sessions: AgentSessionDirectory())
    }

    /// A publish that changes another workspace (or nothing the kit shows)
    /// rebuilds no tab and tells nobody who read `tabs` or `activeTabID`.
    @Test func anotherWorkspaceChangingRebuildsNothing() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let before = source.kitTabBuilds
        let tabs = source.tabs
        #expect(!tabs.isEmpty)
        let notified = SourceChanges()
        withObservationTracking {
            _ = source.tabs
            _ = source.activeTabID
        } onChange: { notified.count += 1 }
        let other = try #require(store.workspaces.first { $0.id != "ws-cmux" })
        store.workspaces = store.workspaces.map { ws in
            var ws = ws
            if ws.id == other.id { ws.lastActivityAt = Date().addingTimeInterval(60); ws.isWorking.toggle() }
            if ws.id == "ws-cmux" { ws.lastActivityAt = Date().addingTimeInterval(30) }
            return ws
        }
        // What the observation's hop does.
        source.refreshTabs()
        #expect(source.kitTabBuilds == before)
        #expect(notified.count == 0)
        #expect(source.tabs == tabs)
    }

    /// Renaming one tab rebuilds that tab only, and publishes the list once.
    @Test func renamingOneTabRebuildsOnlyIt() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let before = source.kitTabBuilds
        let target = try #require(source.tabs.last { $0.kind == .terminal })
        let notified = SourceChanges()
        withObservationTracking { _ = source.tabs } onChange: { notified.count += 1 }
        _ = store.renameTab(target.id, in: "ws-cmux", to: "Renamed")
        source.refreshTabs()
        #expect(source.kitTabBuilds == before + 1)
        #expect(notified.count == 1)
        #expect(source.tabs.first { $0.id == target.id }?.title == "Renamed")
    }

    /// A card reads its own tab's entry: another tab's change does not
    /// notify it.
    @Test func cardEntriesAreObservedPerTab() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let ids = source.tabs.map(\.id)
        #expect(ids.count >= 2)
        let first = try #require(source.entry(ids[0]))
        let notified = SourceChanges()
        withObservationTracking { _ = first.tab } onChange: { notified.count += 1 }
        _ = store.renameTab(ids[1], in: "ws-cmux", to: "Other")
        source.refreshTabs()
        #expect(notified.count == 0)
        _ = store.renameTab(ids[0], in: "ws-cmux", to: "Mine")
        source.refreshTabs()
        #expect(notified.count == 1)
    }

    /// Closing a tab: `tabs` drops it before `close` returns (the kit reads
    /// it at once for Safari's timing).
    @Test func removedTabLeavesTheListAtOnce() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let id = try #require(source.tabs.last?.id)
        _ = store.removeTab(id, from: "ws-cmux")
        source.refreshTabs()
        #expect(!source.tabs.contains { $0.id == id })
        #expect(source.entry(id) == nil)
    }

    /// An agent card's picture: a running turn (its working label animates)
    /// is drawn live; a finished one is drawable, and a changed appearance
    /// or turn makes it stale.
    @Test func agentCardPictureKey() {
        var done = AgentTurn(id: "t1", prompt: "p", promptAt: Date(timeIntervalSince1970: 0))
        done.status = .completed
        let running = AgentTurn(id: "t2", prompt: "p", promptAt: Date(timeIntervalSince1970: 1))
        let key = AgentCardRasterKey(turns: [done], colorScheme: .dark, page: CGSize(width: 402, height: 874),
                                     visibleHeight: 566, topInset: 70, bottomInset: 110, scale: 1.32)
        #expect(key.isDrawable)
        var live = key
        live.turns = [done, running]
        // A running turn is drawn as a still too (its card follows once a second).
        #expect(live.isDrawable)
        var light = key
        light.colorScheme = .light
        #expect(light != key)
        // An image whose bytes are in the turn draws; one still to load (a `.task`) stays live.
        var withBytes = done
        withBytes.attachments = [AgentAttachment(kind: .image, name: "a.png", data: Data([1]))]
        var inline = key
        inline.turns = [withBytes]
        #expect(inline.isDrawable)
        var pending = done
        pending.attachments = [AgentAttachment(kind: .image, name: "b.png")]
        var loading = key
        loading.turns = [pending]
        #expect(!loading.isDrawable)
    }

    /// The grid card resolution follows TabsKit's column card (177 of 402
    /// points), and a lone tab's larger card.
    @Test func cardScaleFollowsTheKitsCard() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        source.pageWidth = 402
        #expect(abs(source.cardScale - 177.0 / 402) < 0.001)
        for tab in source.tabs.dropFirst() { _ = store.removeTab(tab.id, from: "ws-cmux") }
        source.refreshTabs()
        #expect(abs(source.cardScale - 268.0 / 402) < 0.001)
    }

    /// Review finding 1: an agent tab's title comes from its chat store; a
    /// store made after the tab was built (in a page or card body) rebuilds
    /// that tab once, after the update, so its title is not frozen.
    @Test func chatStoreAppearingRebuildsItsTab() async throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let workspace = try #require(source.listedWorkspace)
        let agent = try #require(workspace.tabs.first { $0.kind == .agent })
        let before = source.kitTabBuilds
        _ = source.chatStore(agent, workspace)
        #expect(source.kitTabBuilds == before)
        for _ in 0..<5 { await Task.yield() }
        #expect(source.kitTabBuilds == before + 1)
        // The second read finds the store: nothing more.
        _ = source.chatStore(agent, workspace)
        for _ in 0..<5 { await Task.yield() }
        #expect(source.kitTabBuilds == before + 1)
    }

    /// Review finding 3: a workspace replaced with a new Mac or folder tells
    /// the bodies that read it; another publish (activity) does not.
    @Test func workspaceIdentityChangeNotifiesBodies() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let notified = SourceChanges()
        withObservationTracking { _ = source.listedWorkspace } onChange: { notified.count += 1 }
        store.workspaces = store.workspaces.map { ws in
            var ws = ws
            if ws.id == "ws-cmux" { ws.lastActivityAt = Date().addingTimeInterval(90) }
            return ws
        }
        source.refreshTabs()
        #expect(notified.count == 0)
        store.workspaces = store.workspaces.map { ws in
            var ws = ws
            if ws.id == "ws-cmux" { ws.directory = "~/elsewhere" }
            return ws
        }
        source.refreshTabs()
        #expect(notified.count == 1)
    }

    /// A chat made while the grid scrolls holds its tab's title change until
    /// the grid rests (one list publish then, not one grid body per card).
    @Test func titleChangesWaitForTheGridToRest() async throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let workspace = try #require(source.listedWorkspace)
        let agent = try #require(workspace.tabs.first { $0.kind == .agent })
        source.overviewVisibilityChanged(true)
        source.overviewIdleChanged(false)
        let before = source.kitTabBuilds
        _ = source.chatStore(agent, workspace)
        for _ in 0..<5 { await Task.yield() }
        #expect(source.kitTabBuilds == before)
        source.overviewIdleChanged(true)
        #expect(source.kitTabBuilds == before + 1)
        source.overviewVisibilityChanged(false)
    }

    /// Round 2 (1): while the grid shows, the active chat's live page (its
    /// card) holds its transcript; leaving the grid releases it, and a new
    /// active chat takes the hold.
    @Test func gridHoldsTheActiveTranscript() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        // Two agent chats in the workspace.
        store.workspaces = store.workspaces.map { ws in
            var ws = ws
            if ws.id == "ws-cmux" {
                ws.tabs.append(WorkspaceTab(id: "t-agent-2", kind: .agent, title: "Claude 2", subtitle: "Second chat", harness: "claude"))
            }
            return ws
        }
        let source = Self.source(store)
        let agents = source.tabs.filter { $0.kind == TabsKitTabKind("agent") }
        try #require(agents.count >= 2)
        source.activate(agents[0].id)
        source.overviewWillAppear()
        source.overviewVisibilityChanged(true)
        #expect(source.surface(agents[0].id).holdsTranscript)
        source.activate(agents[1].id)
        #expect(!source.surface(agents[0].id).holdsTranscript)
        #expect(source.surface(agents[1].id).holdsTranscript)
        source.overviewVisibilityChanged(false)
        #expect(!source.surface(agents[1].id).holdsTranscript)
        #expect(!source.showStaticCard(for: agents[1].id))
    }

    /// Round 2 (1): a card's copy changes only on `catchUp()` (the source's
    /// once-a-second follow while the grid rests), never per streamed change.
    @Test func cardFeedCopiesOnlyOnCatchUp() async throws {
        let mock = MockAgentSession(
            summary: AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m"),
            sleep: { _ in await Task.yield() }
        )
        mock.chunkSize = 8
        let chat = AgentChatStore(source: mock)
        while chat.turns.isEmpty { await Task.yield() }
        let feed = AgentCardFeed(store: chat)
        let start = feed.pulls
        let before = chat.turns
        chat.send(prompt: "go")
        // Many streamed changes arrive; the card copies none of them.
        for _ in 0..<2000 where chat.turns == before { await Task.yield() }
        for _ in 0..<200 { await Task.yield() }
        try #require(chat.turns != before)
        #expect(feed.pulls == start)
        #expect(feed.stale)
        feed.catchUp()
        #expect(feed.pulls == start + 1)
        #expect(feed.turns == Array(chat.turns.suffix(2)))
        chat.cancel()
    }

    /// Round 2 (3): opening a workspace makes no web view; a browser tab's
    /// model is made when its page is first shown.
    @Test func browserModelsAreMadeOnFirstPage() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let workspace = try #require(source.listedWorkspace)
        for tab in workspace.tabs where tab.kind == .browser { #expect(source.existingBrowser(tab.id) == nil) }
    }

    /// Review round 3 (HIGH): a picture drawn before a Mac-recorded image
    /// arrived (no bytes yet, so the new key cannot be drawn) must not stand
    /// in: the card shows the live preview. A drawable newer key may show an
    /// older picture of the same layout; another layout never.
    @Test func olderPictureNeverHidesALoadingImage() {
        var done = AgentTurn(id: "t1", prompt: "p", promptAt: Date(timeIntervalSince1970: 0))
        done.status = .completed
        let drawn = AgentCardRasterKey(turns: [done], colorScheme: .dark, page: CGSize(width: 402, height: 874),
                                       visibleHeight: 566, topInset: 70, bottomInset: 110, scale: 1.32)
        #expect(drawn.mayShow(drawn))
        var withImage = done
        withImage.attachments = [AgentAttachment(kind: .image, name: "mac.png")]
        var loading = drawn
        loading.turns = [done, withImage]
        #expect(!loading.mayShow(drawn))
        var newer = drawn
        var next = done
        next.prompt = "q"
        newer.turns = [done, next]
        #expect(newer.mayShow(drawn))
        var light = newer
        light.colorScheme = .light
        #expect(!light.mayShow(drawn))
    }

    /// A tab moving to another of the Mac's screens updates its card's screen chip: the
    /// cards read the listed workspace, which must change when only its screens change.
    @Test func aTabMovingScreensUpdatesItsCardsChip() throws {
        let store = AppStore.mock(tabMemory: .inMemory())
        let source = Self.source(store)
        let ids = try #require(store.workspace(id: "ws-cmux")?.tabs.map(\.id))
        try #require(ids.count >= 2)
        func screens(onSecond: [String]) -> [MacScreen] {
            [MacScreen(id: 1, isActive: true, activePane: 1, panes: [1], tabIDs: ids.filter { !onSecond.contains($0) }),
             MacScreen(id: 2, name: "logs", activePane: 2, panes: [2], tabIDs: onSecond)]
        }
        store.updateWorkspace("ws-cmux") { $0.screens = screens(onSecond: [ids.last!]) }
        source.refreshTabs()
        #expect(source.listedWorkspace?.screenLabel(ofTab: ids[0]) == "Screen 1")
        let notified = SourceChanges()
        withObservationTracking { _ = source.listedWorkspace } onChange: { notified.count += 1 }
        store.updateWorkspace("ws-cmux") { $0.screens = screens(onSecond: [ids[0], ids.last!]) }
        source.refreshTabs()
        #expect(notified.count == 1)
        #expect(source.listedWorkspace?.screenLabel(ofTab: ids[0]) == "logs")
    }
}
#endif
