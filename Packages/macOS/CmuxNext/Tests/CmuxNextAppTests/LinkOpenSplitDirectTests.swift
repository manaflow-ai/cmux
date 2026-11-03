import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-11-03: "it's so slow to open and close ... it's nigh instant for claude and codex", and
/// "the browser/tab opening animation still plays on the main pane before going". A link opened to
/// the right was made as a tab of the source pane, waited for the store to list it, and was then
/// moved to a new split: two daemon round trips, and it showed in the source pane first. With
/// `frontend-browser-tab-split-v1` the link's tab is made in its new split by one
/// `new-frontend-browser-tab {split}`: the split shows at once with a stand-in tab, the source pane
/// never lists the tab, and nothing moves. Carried from austinywang's #23032.
@MainActor struct LinkOpenSplitDirectTests {
    /// What the faked `new-frontend-browser-tab` was asked.
    @MainActor private final class Creates {
        var made: [(pane: PaneID, url: String, after: SurfaceID?, split: ConversationTabSplit?)] = []
        /// The surface a create answers; nil refuses it.
        var reply: SurfaceID?
        /// Hears each create as it is made.
        let (heard, hear) = AsyncStream<Void>.makeStream()
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    /// One pane alone on its screen, on a daemon advertising `capabilities`; browser tab creates are faked.
    private static func pane(capabilities: [DaemonCapability]) throws -> (AppServices, PaneController, Creates) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let list = capabilities.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        let json = #"{"app":"cmux-tui","protocol":1,"session":"split-direct","generation":"g1","capabilities":["# + list + "]}"
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let creates = Creates()
        let browserTabs = services.cache.browserTabs
        browserTabs.serves = { _ in true }
        browserTabs.cefUnavailable = { nil }
        browserTabs.create = { _, pane, url, _, _, _, after, split in
            creates.made.append((pane, url, after, split))
            creates.hear.yield()
            guard let reply = creates.reply else { throw CancellationError() }
            return reply
        }
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: WindowState(record: record))
        return (services, pane, creates)
    }

    private static let served: [DaemonCapability] = [.frontendBrowserTabs, .frontendBrowserTabSplit, .splitClientKeys, .splitClientSplitID]

    @Test(.timeLimit(.minutes(1))) func aLinkToTheRightIsMadeInItsSplitNeverInTheSource() async throws {
        let (services, pane, creates) = try Self.pane(capabilities: Self.served)
        defer { pane.teardown() }
        services.linkOpener.placement = { .splitRight }
        let store = services.daemon.store
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/1"))

        #expect(services.linkOpener.openWeb(url, from: pane, background: false))

        // The split shows now, before any reply: its provisional pane holds the link's stand-in tab.
        let intent = try #require(store.pendingIntents.first)
        guard case .splitPane(let target, let direction, _, let provisional) = intent else {
            Issue.record("the link did not open as a split intent: \(intent)")
            return
        }
        #expect(target == PaneID(rawValue: 1))
        #expect(direction == .right)
        #expect(provisional.tab?.kind == .browser)
        #expect(provisional.tab?.url == url.absoluteString)
        let screen = try #require(store.workspaces.first?.screens.first)
        #expect(screen.panes.count == 2, "the new split did not show at once")
        #expect(store.pane(PaneID(rawValue: 1))?.tabs.map(\.surface) == [SurfaceID(rawValue: 1)], "the link's tab showed in the source pane")

        if creates.made.isEmpty { for await _ in creates.heard { break } }
        try #require(creates.made.count == 1, "one new-frontend-browser-tab, not a create and a move")
        let made = creates.made[0]
        #expect(made.pane == PaneID(rawValue: 1))
        #expect(made.url == url.absoluteString)
        #expect(made.after == nil)
        #expect(made.split == ConversationTabSplit(direction: .right, paneID: provisional.paneID, splitID: provisional.splitID))

        // The refused create ended the open's turn (`finished`, then RightColumnTurns' `done`): the next
        // link beside the same pane is asked of the daemon too, not queued behind it forever.
        #expect(services.linkOpener.openWeb(url, from: pane, background: false))
        if creates.made.count < 2 { for await _ in creates.heard { break } }
        #expect(creates.made.count == 2, "the first split open never ended its turn")
    }

    /// An older daemon (no `frontend-browser-tab-split-v1`) keeps the make-and-move path: the tab is
    /// asked of the source pane with no `split`, which that daemon would ignore.
    @Test(.timeLimit(.minutes(1))) func withoutTheCapabilityTheTabIsMadeInTheSourceAndMoved() async throws {
        let (services, pane, creates) = try Self.pane(capabilities: [.frontendBrowserTabs, .splitClientKeys])
        defer { pane.teardown() }
        #expect(!PaneBrowserTabOpener(controller: pane).opensInSplit)
        services.linkOpener.placement = { .splitRight }
        let url = try #require(URL(string: "https://example.com/"))
        #expect(services.linkOpener.openWeb(url, from: pane, background: false))
        #expect(!services.daemon.store.pendingIntents.contains { if case .splitPane = $0 { true } else { false } })
        if creates.made.isEmpty { for await _ in creates.heard { break } }
        try #require(creates.made.count == 1)
        #expect(creates.made[0].split == nil)
    }

    /// A column is no daemon split: `.newColumn` keeps the move, and a split maker is not asked.
    @Test func aNewColumnStillMoves() throws {
        let (services, pane, _) = try Self.pane(capabilities: Self.served)
        defer { pane.teardown() }
        services.linkOpener.placement = { .newColumn }
        var split = false, moved = false
        services.linkOpener.open(from: pane, split: { _, _, _ in
            split = true
            return true
        }) { _, placed in
            moved = placed != nil
            return true
        }
        #expect(!split)
        #expect(moved)
    }

    /// A split maker that answers nil (its daemon cannot) falls back to make-and-move.
    @Test func aSplitMakerThatCannotFallsBackToTheMove() throws {
        let (services, pane, _) = try Self.pane(capabilities: Self.served)
        defer { pane.teardown() }
        services.linkOpener.placement = { .splitRight }
        var direction: SplitDirection?, moved = false
        services.linkOpener.open(from: pane, split: { _, side, _ in
            direction = side
            return nil
        }) { _, placed in
            moved = placed != nil
            return true
        }
        #expect(direction == .right)
        #expect(moved)
    }

    /// The reply can come before the daemon's pane (review of #32900): the open's turn ends only once
    /// the store lists the new tab, so the next link beside the pane never aims at the provisional pane.
    @Test(.timeLimit(.minutes(1))) func theTurnWaitsForTheDaemonsPaneNotJustTheReply() async throws {
        let (services, pane, creates) = try Self.pane(capabilities: Self.served)
        defer { pane.teardown() }
        services.linkOpener.placement = { .splitRight }
        let store = services.daemon.store
        let made = SurfaceID(rawValue: 7)
        creates.reply = made
        let url = try #require(URL(string: "https://example.com/"))
        #expect(services.linkOpener.openWeb(url, from: pane, background: false))
        if creates.made.isEmpty { for await _ in creates.heard { break } }
        #expect(services.linkOpener.openWeb(url, from: pane, background: false))
        for _ in 0..<20 { await Task.yield() }
        #expect(creates.made.count == 1, "the next open went out before the daemon's pane arrived")

        // The daemon's pane arrives: the turn ends and the queued open is asked.
        let source = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let right = PaneSnapshot(id: PaneID(rawValue: 2), tabs: [TabSnapshot(surface: made, title: url.absoluteString)])
        let layout = LayoutNode.split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(PaneID(rawValue: 1)), b: .leaf(PaneID(rawValue: 2)))
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: [source, right])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])]))
        if creates.made.count < 2 { for await _ in creates.heard { break } }
        #expect(creates.made.count == 2)
    }

    /// Leo 2026-11-03: "the new tab at the top opening first in the main pane THEN in the right split ... that top
    /// tab animation". Split Browser Right (its key, menus, link hints' `F`, an agent's browser beside it) made the
    /// tab in the source pane and then moved it with `split {tab}`, so the strip's new-tab animation played there
    /// first. Now the split shows with its stand-in in the action's turn and one create carries `split`.
    @Test(.timeLimit(.minutes(1))) func splitBrowserRightIsMadeInItsSplitNeverInTheSource() async throws {
        let (services, pane, creates) = try Self.pane(capabilities: Self.served)
        defer { pane.teardown() }
        let store = services.daemon.store

        _ = try BrowserHandlers.splitBrowser(from: pane, direction: .right, byPerson: true, context: AppActionContext(services: services))

        let intent = try #require(store.pendingIntents.first, "no split showed in the action's turn")
        guard case .splitPane(let target, let direction, _, let provisional) = intent else {
            Issue.record("Split Browser did not open as a split intent: \(intent)")
            return
        }
        #expect(target == PaneID(rawValue: 1))
        #expect(direction == .right)
        #expect(provisional.tab?.kind == .browser)
        #expect(store.pane(PaneID(rawValue: 1))?.tabs.map(\.surface) == [SurfaceID(rawValue: 1)], "the new tab showed in the source pane")

        if creates.made.isEmpty { for await _ in creates.heard { break } }
        try #require(creates.made.count == 1, "one new-frontend-browser-tab, not a create and a move")
        #expect(creates.made[0].pane == PaneID(rawValue: 1))
        #expect(creates.made[0].split == ConversationTabSplit(direction: .right, paneID: provisional.paneID, splitID: provisional.splitID))
    }

    /// An incognito pane keeps make-and-move: its daemon record holds about:blank until the reply
    /// registers the URL, so a pane that arrived first would mount a blank page (review of #32900).
    @Test func anIncognitoPaneKeepsTheMove() throws {
        let (services, pane, _) = try Self.pane(capabilities: Self.served)
        defer { pane.teardown() }
        services.cache.browserTabs.isIncognitoPane = { _ in true }
        #expect(!PaneBrowserTabOpener(controller: pane).opensInSplit)
    }
}
