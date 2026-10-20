import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// Lawrence 2026-10-19: "I opened a tab... I'm on a home page and then I clicked it and then it
/// opened in the same column... Ideally it opens in the pane to the right." What a New Tab page
/// opens (a terminal, a browser, a chat) took the page's place in its pane; now, like every link
/// (``LinkOpener``), it goes to the pane on the right or a new split there. A page alone in its
/// pane, a split's page and Same Pane still replace in place.
@MainActor struct NewTabPageOpensBesideTests {
    /// A pane holding a terminal (surface 1) and the New Tab page (surface 2), or the page alone.
    private static func pane(withTerminal: Bool) throws -> (AppServices, PaneController, String) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let surfaces: [UInt64] = withTerminal ? [1, 2] : [2]
        let snapshot = PaneSnapshot(id: PaneID(rawValue: 1), tabs: surfaces.map { TabSnapshot(surface: SurfaceID(rawValue: $0), title: "~") })
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [snapshot])
        services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])]))
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let page = try #require(services.daemon.store.tab(surface: SurfaceID(rawValue: 2))).id
        services.agentTabs.newTabPages[page] = (AgentPaneNewTab(kind: .agent), NewTabPageHandler(open: { _, _ in }, jump: { _, _ in }, editShortcut: { _ in }))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: WindowState(record: record))
        return (services, pane, page)
    }

    @Test func aPickOnANewTabPageBesideAnotherTabOpensToTheRight() throws {
        let (_, pane, page) = try Self.pane(withTerminal: true)
        defer { pane.teardown() }
        #expect(NewTabPage.opensBeside(page, in: pane), "the page's pick replaced it in the same pane")
    }

    @Test func samePaneKeepsTheReplaceInPlace() throws {
        let (services, pane, page) = try Self.pane(withTerminal: true)
        defer { pane.teardown() }
        services.linkOpener.placement = { .samePane }
        #expect(!NewTabPage.opensBeside(page, in: pane))
    }

    /// Nothing else in the pane to keep in view: the page becomes what it opened.
    @Test func aLonePageIsReplacedInPlace() throws {
        let (_, pane, page) = try Self.pane(withTerminal: false)
        defer { pane.teardown() }
        #expect(!NewTabPage.opensBeside(page, in: pane))
    }

    /// A split's page (it lists Open Tabs) fills the pane the person just made.
    @Test func aSplitsPageIsReplacedInPlace() throws {
        let (services, pane, page) = try Self.pane(withTerminal: true)
        defer { pane.teardown() }
        var split = AgentPaneNewTab(kind: .agent)
        split.openTabs = []
        services.agentTabs.newTabPages[page]?.page = split
        #expect(!NewTabPage.opensBeside(page, in: pane))
    }
}
