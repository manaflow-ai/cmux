import AppKit
import CmuxNextAgentPane
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-10-20: "when you open up a new tab ... if you came from a split workspace pane session,
/// then it goes, like, the layout shifts and splits." Since 2026-10-19 what a New Tab page opened
/// beside another tab (a terminal, a browser, a chat card) went through ``LinkOpener``: to the pane
/// on the right, else a new split, and the page's pane fell back to its old tab. The New Tab page
/// is the tab the person opened in this pane: its pick takes the page's place there, whatever
/// `layout.linkPlacement` says, and no pane or divider moves. `layout.newTabPageFollowsLinkPlacement`
/// opts back into the link rule (Lawrence 2026-10-19).
@MainActor struct NewTabPagePickInPlaceTests {
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

    /// Runs the page's terminal pick and reports whether it asked where links go (a pick routed
    /// through ``LinkOpener`` reads `layout.linkPlacement` to find the pane on the right or split).
    private static func pickConsultsLinkPlacement(_ placement: LinkPlacement, withTerminal: Bool, optedIn: Bool = false) throws -> Bool {
        let (services, pane, page) = try Self.pane(withTerminal: withTerminal)
        defer { pane.teardown() }
        services.linkOpener.newTabPageFollows = { optedIn }
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

    /// The opt-in setting is off unless the person turns it on.
    @Test func followingLinkPlacementIsOptIn() {
        #expect(!CmuxConfigSnapshot.newTabPageFollowsLinkPlacementFallback)
    }

    /// `layout.newTabPageFollowsLinkPlacement` on: the pick goes where links go, beside the page.
    @Test func optedInThePickFollowsLinkPlacement() throws {
        #expect(try Self.pickConsultsLinkPlacement(.splitRight, withTerminal: true, optedIn: true))
        let (_, pane, page) = try Self.pane(withTerminal: true)
        defer { pane.teardown() }
        pane.services.linkOpener.newTabPageFollows = { true }
        #expect(NewTabPage.opensBeside(page, in: pane))
        pane.services.linkOpener.newTabPageFollows = { false }
        #expect(!NewTabPage.opensBeside(page, in: pane))
    }
}
