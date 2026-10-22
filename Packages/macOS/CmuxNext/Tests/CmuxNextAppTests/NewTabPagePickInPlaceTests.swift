import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-10-20: "when you open up a new tab ... if you came from a split workspace pane session,
/// then it goes, like, the layout shifts and splits." Since 2026-10-19 what a New Tab page opened
/// beside another tab (a terminal, a browser, a chat card) went through ``LinkOpener``: to the pane
/// on the right, else a new split, and the page's pane fell back to its old tab. The New Tab page
/// is the tab the person opened in this pane: its pick takes the page's place there, whatever
/// `layout.linkPlacement` says, and no pane or divider moves. The Debug toggle `newTab.picksFollowLinks`
/// opts back into the link rule (Lawrence 2026-10-19). Serialized: the toggle is the shared store's.
@MainActor @Suite(.serialized) struct NewTabPagePickInPlaceTests {
    @Test(arguments: [
        (AgentPaneTabKind.terminal, true, true),
        (AgentPaneTabKind.browser, true, true),
        (AgentPaneTabKind.agent, true, false),
        (AgentPaneTabKind.terminal, false, false),
        (AgentPaneTabKind.browser, false, false),
        (AgentPaneTabKind.agent, false, false),
    ])
    func dockPagesRouteOnlyToolPicksToTheStrip(kind: AgentPaneTabKind, dock: Bool, expected: Bool) {
        #expect(NewTabPage.pickOpensInStrip(kind, inChatDock: dock) == expected)
    }

    /// A pane holding a terminal (surface 1) and the New Tab page (surface 2), or the page alone, with
    /// the Debug toggle `newTab.picksFollowLinks` on (`optedIn`) or at its default.
    private static func pane(withTerminal: Bool, optedIn: Bool = false) throws -> (AppServices, PaneController, String) {
        _ = NSApplication.shared
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(AgentPaneTunables.all)
        _ = store.set(AgentPaneTunables.newTabPicksFollowLinks.key, optedIn ? .bool(true) : nil)
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

    /// Runs the page's terminal pick and reports whether it asked where links go (a pick routed
    /// through ``LinkOpener`` reads `layout.linkPlacement` to find the pane on the right or split).
    private static func pickConsultsLinkPlacement(_ placement: LinkPlacement, withTerminal: Bool, optedIn: Bool = false) throws -> Bool {
        let (services, pane, page) = try Self.pane(withTerminal: withTerminal, optedIn: optedIn)
        defer {
            pane.teardown()
            _ = TunableStore.shared.set(AgentPaneTunables.newTabPicksFollowLinks.key, nil)
        }
        var consulted = false
        services.linkOpener.placement = {
            consulted = true
            return placement
        }
        NewTabPage.replace(page, with: AgentPaneOpenTab(kind: .terminal, text: "", run: false), cwd: nil, in: pane)
        return consulted
    }

    @Test func aPickOnANewTabPageBesideAnotherTabTakesThePagesPlace() throws {
        #expect(try !Self.pickConsultsLinkPlacement(.splitRight, withTerminal: true),
                "the page's pick went to the pane on the right or a new split instead of the page's tab")
        #expect(try !Self.pickConsultsLinkPlacement(.newColumn, withTerminal: true),
                "the page's pick went to a new column instead of the page's tab")
    }

    /// Nothing else in the pane: the page becomes what it opened, as it always did.
    @Test func aLonePageIsReplacedInPlace() throws {
        #expect(try !Self.pickConsultsLinkPlacement(.splitRight, withTerminal: false))
    }

    /// The Debug toggle is off unless someone turns it on.
    @Test func followingLinksIsOptIn() {
        #expect(!AgentPaneTunables.newTabPicksFollowLinks.defaultValue)
    }

    /// `newTab.picksFollowLinks` on: the pick goes where links go, beside the page.
    @Test func optedInThePickFollowsLinkPlacement() throws {
        #expect(try Self.pickConsultsLinkPlacement(.splitRight, withTerminal: true, optedIn: true))
        let (_, pane, page) = try Self.pane(withTerminal: true, optedIn: true)
        defer {
            pane.teardown()
            _ = TunableStore.shared.set(AgentPaneTunables.newTabPicksFollowLinks.key, nil)
        }
        #expect(NewTabPage.opensBeside(page, in: pane))
    }
}
