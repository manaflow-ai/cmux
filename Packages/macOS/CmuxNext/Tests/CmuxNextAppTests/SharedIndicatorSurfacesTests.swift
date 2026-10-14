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
        store.session.apply(item, to: store.workspaces)
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
        row.configure(SidebarWorkspaceItems.workspaceInfo(workspace), style: .list)
        #expect(shown(row) == (busy ? .working(progress: nil) : nil))
    }

    @Test(arguments: [true, false])
    func theWorkspaceHoverCardShowsItsIndicator(busy: Bool) throws {
        let workspace = try #require(try store(busy: busy).workspaces.first)
        let card = WorkspaceHoverCardView()
        card.configure(.make(SidebarMapping.shared.row(workspace, machine: .local), machine: nil, now: Date()))
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
    /// off it never shows.
    @Test func aPlainCommandShowsBusyOnlyAfterItsThreshold() async throws {
        let saved = DesignSettings.shared.statusBehavior
        defer { DesignSettings.shared.statusBehavior = saved }
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        func tab(startedMsAgo age: UInt64) throws -> TabModel {
            let extra = #"{"busy":{"since_ms":"\#(nowMs - age)"}}"#
            return try #require(try store(extra: extra).workspaces.first?.screens.first?.panes.first?.tabs.first)
        }
        func shown(_ tab: TabModel) -> StatusIndicatorState? {
            let card = TabHoverCardView()
            card.configure(.tab(TabItemMapping.shared.item(tab, fallbackTitle: "zsh")))
            return self.shown(card)
        }

        DesignSettings.shared.statusBehavior.inferCommandBusy = false
        #expect(try shown(tab(startedMsAgo: 60_000)) == nil)

        DesignSettings.shared.statusBehavior.inferCommandBusy = true
        DesignSettings.shared.statusBehavior.inferCommandBusyAfter = 3
        #expect(try shown(tab(startedMsAgo: 60_000)) == .busy(progress: nil))

        DesignSettings.shared.statusBehavior.inferCommandBusyAfter = 0.3
        let young = try tab(startedMsAgo: 0)
        #expect(shown(young) == nil)
        #expect(young.commandRecheck == 0)
        let deadline = ContinuousClock.now + .seconds(5)
        while young.commandRecheck == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(young.commandRecheck == 1)
        #expect(shown(young) == .busy(progress: nil))
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
