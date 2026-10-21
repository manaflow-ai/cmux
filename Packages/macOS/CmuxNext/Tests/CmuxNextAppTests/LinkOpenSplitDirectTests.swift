import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// User report 2026-10-20: a pull request's link in an agent chat (or a terminal's Cmd-click) that
/// opens to the right first showed as another tab of the chat's pane, then slid into a new split:
/// the tab was made in the source pane and moved (`move-tab-to-split`). With
/// `frontend-browser-tab-split-v1` the link's tab is made in its new split in one
/// `new-frontend-browser-tab {split}`: the split shows at once with a stand-in tab, the source
/// pane never lists the tab, and nothing moves.
@MainActor struct LinkOpenSplitDirectTests {
    /// What the faked `new-frontend-browser-tab` was asked.
    @MainActor private final class Creates {
        var made: [(pane: PaneID, url: String, after: SurfaceID?, split: ConversationTabSplit?)] = []
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    /// One pane alone on its screen, on a daemon advertising `capabilities`; browser tab creates are faked.
    private static func pane(capabilities: [String]) throws -> (AppServices, PaneController, Creates) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"{"app":"cmux-tui","protocol":1,"session":"split-direct","generation":"g1","capabilities":["# + list + "]}"
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree())
        let creates = Creates()
        services.cache.browserTabs.create = { _, pane, url, _, _, _, after, split in
            creates.made.append((pane, url, after, split))
            return SurfaceID(rawValue: 900)
        }
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: WindowState(record: record))
        return (services, pane, creates)
    }

    private static let served = [DaemonCapabilities.shared.frontendBrowserTabs, DaemonCapabilities.shared.frontendBrowserTabSplit,
                                 DaemonCapabilities.shared.splitClientSplitID]

    @Test func aCmdClickToTheRightMakesTheTabInItsSplitNeverInTheSource() async throws {
        let (services, pane, creates) = try Self.pane(capabilities: Self.served)
        defer { pane.teardown() }
        services.linkOpener.placement = { .splitRight }
        let store = services.daemon.store
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/1"))

        services.linkOpener.openWeb(url, from: pane, background: false, cmdClick: true)

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
        #expect(screen.panes.first?.tabs.count == 1, "the link's tab showed in the source pane")

        let deadline = ContinuousClock.now + .seconds(2)
        while creates.made.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(creates.made.count == 1, "one new-frontend-browser-tab, not a create and a move")
        let made = creates.made[0]
        #expect(made.pane == PaneID(rawValue: 1))
        #expect(made.url == url.absoluteString)
        #expect(made.after == nil)
        #expect(made.split == ConversationTabSplit(direction: .right, paneID: provisional.paneID, splitID: provisional.splitID))
        #expect(store.pane(PaneID(rawValue: 1))?.tabs.map(\.surface) == [SurfaceID(rawValue: 1)],
                "the source pane listed the link's tab")
    }

    /// An older daemon (no `frontend-browser-tab-split-v1`) keeps the make-and-move path, and the
    /// split sends no `split`, which that daemon would ignore by making the tab in the source.
    @Test func withoutTheCapabilityTheTabIsMadeInTheSourceAndMoved() throws {
        let (services, pane, _) = try Self.pane(capabilities: [DaemonCapabilities.shared.frontendBrowserTabs])
        defer { pane.teardown() }
        #expect(!pane.opensBrowserSplitsDirectly)
        services.linkOpener.placement = { .splitRight }
        var moved = false
        let opened = services.linkOpener.open(from: pane, cmdClick: true, split: { _, _ in nil }) { _, placed in
            moved = placed != nil
            return true
        }
        #expect(opened)
        #expect(moved, "a split that cannot be made directly did not fall back to the move")
    }

    @Test func withTheCapabilityTheSplitIsDirect() throws {
        let (services, pane, _) = try Self.pane(capabilities: Self.served)
        defer { pane.teardown() }
        #expect(pane.opensBrowserSplitsDirectly)
        services.linkOpener.placement = { .splitRight }
        var split: SplitDirection?, made = false
        let opened = services.linkOpener.open(from: pane, cmdClick: true, split: { _, direction in
            split = direction
            return true
        }) { _, _ in
            made = true
            return true
        }
        #expect(opened)
        #expect(split == .right)
        #expect(!made, "the item was made in the source pane as well")
    }

    /// A column is no daemon split: `.newColumn` keeps the move.
    @Test func aNewColumnStillMoves() throws {
        let (services, pane, _) = try Self.pane(capabilities: Self.served)
        defer { pane.teardown() }
        services.linkOpener.placement = { .newColumn }
        var split = false, moved = false
        services.linkOpener.open(from: pane, cmdClick: true, split: { _, _ in
            split = true
            return true
        }) { _, placed in
            moved = placed != nil
            return true
        }
        #expect(!split)
        #expect(moved)
    }

    @Test func onlyARightOrBottomDropSplitsDirectly() {
        #expect(LinkOpener.splitDirection(.right) == .right)
        #expect(LinkOpener.splitDirection(.bottom) == .down)
        #expect(LinkOpener.splitDirection(.left) == nil)
        #expect(LinkOpener.splitDirection(.top) == nil)
    }
}
