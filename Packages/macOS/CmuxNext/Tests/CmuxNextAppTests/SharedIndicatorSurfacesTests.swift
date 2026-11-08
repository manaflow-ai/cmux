import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextHome
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Foundation
import Testing

/// Every surface that shows a tab's or workspace's state draws the one shared indicator
/// (`StatusIndicatorView`, `appearance.statusIndicator.style`; cx-ag5.2, status-indicators.md 8):
/// a sidebar section item, the workspace and tab hover cards, and Home's agent rows. A workspace
/// whose program reports work in progress shows it on each; a quiet one shows none.
@MainActor
struct SharedIndicatorSurfacesTests {
    /// A store with one terminal tab; `busy` has its program report work in progress (an OSC 7501
    /// `working` record, `extra.program_status`). A plain shell command no longer shows busy by
    /// default (cx-ag5.6.5, `status.inferCommandBusy`).
    func store(busy: Bool) throws -> DaemonStore {
        try store(extra: busy ? #"{"program_status":[{"id":"","state":"working","app":"cargo","updated_seq":"1"}]}"# : "{}")
    }

    /// A store with one terminal tab whose terminal record carries `extra`.
    func store(extra: String) throws -> DaemonStore {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_7")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"terminals":[{"id":"term_7","extra":\#(extra)}],"extra":{"state":{}}}}}"#
        let item = try #require(SessionStreamItem.decode(Data(line.utf8)))
        store.session.apply(item, in: store)
        return store
    }

    /// The state of the visible shared indicator in `view`'s tree, nil when none draws.
    func shown(_ view: NSView) -> StatusIndicatorState? {
        if let indicator = view as? StatusIndicatorView, !indicator.isHidden, indicator.state != .idle { return indicator.state }
        return view.subviews.lazy.compactMap(shown).first
    }

    @Test(arguments: [true, false])
    func aSectionItemShowsItsWorkspacesIndicator(busy: Bool) throws {
        let workspace = try #require(try store(busy: busy).workspaces.first)
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        row.configure(SidebarWorkspaceItems.workspaceInfo(workspace, machine: .local), style: .list)
        #expect(shown(row) == (busy ? .working(progress: nil) : nil))
    }

    @Test(arguments: [true, false])
    func theWorkspaceHoverCardShowsItsIndicator(busy: Bool) throws {
        let workspace = try #require(try store(busy: busy).workspaces.first)
        let card = WorkspaceHoverCardView()
        card.configure(.make(SidebarMapping.shared.row(workspace, machine: .local), machine: nil, now: Date()))
        card.detailsToggle.performClick(nil)
        #expect(shown(card) == (busy ? .working(progress: nil) : nil))
    }

    @Test(arguments: [true, false])
    func theTabHoverCardShowsItsIndicator(busy: Bool) throws {
        let tab = try #require(try store(busy: busy).workspaces.first?.screens.first?.panes.first?.tabs.first)
        let card = TabHoverCardView()
        card.configure(.tab(TabItemMapping.shared.item(tab, fallbackTitle: "zsh")))
        #expect(shown(card) == (busy ? .working(progress: nil) : nil))
    }

    /// U3/U7 (cx-6so.11): with `status.inferCommandBusy` on, a plain shell command (the daemon's
    /// `extra.busy.since_ms`, OSC 133 C..D) shows busy once it has run `inferCommandBusyAfter`; a
    /// younger one shows nothing until its one-shot recheck fires (no polling), and with the setting
    /// off it never shows. A daemon whose clock runs ahead counts from when this client saw the command.
    @Test func aPlainCommandShowsBusyOnlyAfterItsThreshold() async throws {
        let saved = DesignSettings.shared.statusBehavior
        defer { DesignSettings.shared.statusBehavior = saved }
        func tab(startedMsAgo age: Int64) throws -> TabModel {
            let since = Int64(Date().timeIntervalSince1970 * 1000) - age
            let extra = #"{"busy":{"since_ms":"\#(since)"}}"#
            return try #require(try store(extra: extra).workspaces.first?.screens.first?.panes.first?.tabs.first)
        }
        // Sets the behavior and reads the indicator with no suspension between, so another suite's
        // settings apply on the main actor cannot land in between.
        func shown(_ tab: TabModel, infer: Bool, after: Double) -> StatusIndicatorState? {
            DesignSettings.shared.statusBehavior.inferCommandBusy = infer
            DesignSettings.shared.statusBehavior.inferCommandBusyAfter = after
            let card = TabHoverCardView()
            card.configure(.tab(TabItemMapping.shared.item(tab, fallbackTitle: "zsh")))
            return self.shown(card)
        }

        #expect(try shown(tab(startedMsAgo: 60_000), infer: false, after: 3) == nil)
        #expect(try shown(tab(startedMsAgo: 60_000), infer: true, after: 3) == .busy(progress: nil))

        // A minute in the future by the daemon's clock: as young as when this client saw it.
        let young = try tab(startedMsAgo: -60_000)
        #expect(shown(young, infer: true, after: 1) == nil)
        #expect(young.commandRecheck == 0)
        let deadline = ContinuousClock.now + .seconds(10)
        while young.commandRecheck == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(young.commandRecheck == 1)
        #expect(shown(young, infer: true, after: 1) == .busy(progress: nil))
    }

    @Test func homesAgentRowsShowTheirStateInTheIndicator() throws {
        let home = HomeFirstRunView(frame: .zero)
        home.setAgents([
            HomeAgentGlance(id: "a", title: "claude", icon: .agentChat, status: .working),
            HomeAgentGlance(id: "b", title: "codex", icon: .agentChat, status: .needsYou),
            HomeAgentGlance(id: "c", title: "amp", icon: .agentChat, status: .idle),
        ])
        let rows = Dictionary(uniqueKeysWithValues: home.agentRows.map { ($0.title, $0) })
        #expect(try shown(#require(rows["codex"])) == .waiting(kind: nil))
        #expect(try shown(#require(rows["claude"])) == .working(progress: nil))
        #expect(try shown(#require(rows["amp"])) == nil)
    }
}
