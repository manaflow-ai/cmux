import CmuxNextIcons
import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextBridge
@testable import CmuxNextDaemon

@MainActor
struct SidebarMappingTests {
    @Test func loneMachineSectionListsWorkspacesInDaemonOrder() throws {
        let store = try BridgeFixture.store()
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let sections = SidebarMapping.shared.sections(store.sidebarSections, machine: machine)
        #expect(sections.count == 1)
        #expect(sections[0].workspaces.map(\.title) == ["beta", "gamma"])
        // One unread marker on the first tab of beta.
        #expect(sections[0].workspaces[0].unread == .count(1))
    }

    /// The daemon's workspace status is the live line and its progress the
    /// bar; without a status, a terminal's parsed OSC 9;4 progress shows.
    @Test func daemonStatusIsTheLiveLineAndCwdStaysPassive() throws {
        let store = try BridgeFixture.store()
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        // The cwd never becomes a second line on its own.
        let plain = SidebarMapping.shared.sections(store.sidebarSections, machine: machine)
        for ws in plain[0].workspaces { #expect(ws.liveDetail == nil && ws.progress == nil) }

        let beta = try #require(store.sidebarSections.flatMap(\.workspaces).first { $0.displayName == "beta" })
        let terminal = try #require(beta.screens.flatMap(\.panes).flatMap(\.tabs).first?.terminalResourceID)
        let betaID = try #require(beta.resourceID)
        var state = SessionStateMirror()
        state.workspaceStatus[betaID] = WorkspaceStatus(workspaceID: betaID, entries: [.init(key: "agent", text: "Running")],
                                                        progress: .init(value: 0.5))
        state.terminalProgress[terminal] = TerminalProgressReport(state: .error, value: 30)
        store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: .sessionState(.snapshot(state)))])

        let mapped = { try #require(SidebarMapping.shared.sections(store.sidebarSections, machine: machine)[0].workspaces.first { $0.title == "beta" }) }
        #expect(try mapped().status == "Running")
        #expect(try mapped().liveDetail == "Running")
        #expect(try mapped().progress == SidebarProgress(value: 0.5))
        #expect(try mapped().subtitle == plain[0].workspaces.first { $0.title == "beta" }?.subtitle)

        // Without a reported progress, the terminal's parsed one shows.
        state.workspaceStatus[betaID]?.progress = nil
        store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: .sessionState(.snapshot(state)))])
        #expect(try mapped().progress == SidebarProgress(value: 0.3, isError: true))
    }

    /// Workspace rows keep a visible type glyph even when the workspace has
    /// no user icon, and the glyph says what the row shows: the selected tab
    /// of its most recently focused pane. A tab in another pane does not
    /// change it, and a workspace with no tabs keeps the terminal fallback.
    @Test func rowKindFollowsTheSelectedTab() throws {
        let store = try BridgeFixture.store()
        let beta = try #require(store.workspaces.first { $0.displayName == "beta" })
        let panes = beta.screens.flatMap(\.panes)
        // Pane 16 (focused last) shows surface 15; pane 4 holds surfaces 3 and 13.
        let front = try #require(panes.max { $0.focusedAt < $1.focusedAt }?.tabs.first)
        let background = try #require(panes.first { $0.handle == PaneID(rawValue: 4) })
        let row = { SidebarMapping.shared.row(beta, machine: .local) }

        #expect(row().kind == .terminal)
        background.tabs[0].kind = .browser
        background.tabs[0].setAgent(AgentStatus(surface: background.tabs[0].surface, state: .working, agent: "claude"))
        #expect(row().kind == .terminal)
        #expect(row().kindBrand == nil)

        front.kind = .browser
        #expect(row().kind == .browser)
        front.kind = .pty
        front.setAgent(AgentStatus(surface: front.surface, state: .idle, agent: "codex"))
        #expect(row().kind == .harness)
        #expect(row().kindBrand == "openai")

        let gamma = try #require(store.workspaces.first { $0.displayName == "gamma" })
        #expect(SidebarMapping.shared.row(gamma, machine: .local).kind == .terminal)
    }

    /// A row whose selected tab is an agent chat wears the chat's harness mark.
    @Test func anAgentChatRowWearsItsHarnessMark() throws {
        let store = try BridgeFixture.store()
        let beta = try #require(store.workspaces.first { $0.displayName == "beta" })
        let front = try #require(beta.screens.flatMap(\.panes).max { $0.focusedAt < $1.focusedAt }?.tabs.first)
        let line = """
        {"surface":\(front.surface.rawValue),"kind":"conversation","browser_renderer":"frontend","title":"about:blank",
         "conversation":{"agent_session":{"host":"install:mac-1","session":"s-1","harness":"claude"}}}
        """
        front.update(try JSONDecoder().decode(TabSnapshot.self, from: Data(line.utf8)))
        let row = SidebarMapping.shared.row(beta, machine: .local)
        #expect(row.kind == .harness)
        #expect(row.kindBrand == "claude")
    }

    /// A tab still on the New Tab page lists as a new tab (the registry's
    /// new-tab icon), not as an agent chat; the workspace row's own kind is
    /// unchanged.
    @Test func aNewTabPageTabListsAsANewTab() throws {
        let store = try BridgeFixture.store()
        let beta = try #require(store.workspaces.first { $0.displayName == "beta" })
        let front = try #require(beta.screens.flatMap(\.panes).max { $0.focusedAt < $1.focusedAt }?.tabs.first)
        let line = """
        {"surface":\(front.surface.rawValue),"kind":"conversation","browser_renderer":"frontend","title":"about:blank",
         "conversation":{"agent_session":{"host":"install:mac-1","session":"s-1","harness":"claude"}}}
        """
        front.update(try JSONDecoder().decode(TabSnapshot.self, from: Data(line.utf8)))
        let chat = SidebarMapping.shared.row(beta, machine: .local)
        #expect(chat.tabs.first { $0.id == TabID(front.id) }?.kind == .agentChat)
        let page = SidebarMapping.shared.row(beta, machine: .local, newTabPages: [front.id])
        let listed = try #require(page.tabs.first { $0.id == TabID(front.id) })
        #expect(listed.kind == .newTab)
        #expect(listed.kind.icon == .tabNew)
        #expect(page.kind == chat.kind)
    }

    /// A New Tab page tab is listed as "New Tab", like the tab strip, not by
    /// its record's blank-page address.
    @Test func aNewTabPageTabListsUnderTheNewTabTitle() throws {
        let store = try BridgeFixture.store()
        let beta = try #require(store.workspaces.first { $0.displayName == "beta" })
        let front = try #require(beta.screens.flatMap(\.panes).max { $0.focusedAt < $1.focusedAt }?.tabs.first)
        let line = """
        {"surface":\(front.surface.rawValue),"kind":"conversation","browser_renderer":"frontend","title":"about:blank",
         "conversation":{"agent_session":{"host":"install:mac-1","session":"s-1","harness":"claude"}}}
        """
        front.update(try JSONDecoder().decode(TabSnapshot.self, from: Data(line.utf8)))
        let page = SidebarMapping.shared.row(beta, machine: .local, newTabPages: [front.id], newTabTitle: "New Tab")
        #expect(page.tabs.first { $0.id == TabID(front.id) }?.title == "New Tab")
        let chat = SidebarMapping.shared.row(beta, machine: .local, newTabTitle: "New Tab")
        #expect(chat.tabs.first { $0.id == TabID(front.id) }?.title == front.displayTitle)
    }

    /// The window's own tab selection picks the tab, over the daemon's default.
    @Test func theWindowSelectionPicksTheRowTab() throws {
        let store = try BridgeFixture.store()
        let beta = try #require(store.workspaces.first { $0.displayName == "beta" })
        let pane = try #require(beta.screens.flatMap(\.panes).first { $0.handle == PaneID(rawValue: 4) })
        pane.focusedAt = 99
        pane.tabs[0].kind = .browser
        // The daemon default of pane 4 is its second tab, a terminal.
        #expect(SidebarMapping.shared.row(beta, machine: .local).kind == .terminal)
        let selected = SidebarMapping.shared.row(beta, machine: .local, selectedTab: { $0 === pane ? pane.tabs[0].id : nil })
        #expect(selected.kind == .browser)
    }

    @Test func dropPositionMapsToRootIndexAfterRemoval() {
        let rows = ["a", "b", "c", "d"].map { SidebarWorkspace(id: SidebarWorkspaceID($0), title: $0) }
        let machine = SidebarMachine(id: .local, name: "Mac", kind: .local)
        let sections = [SidebarRowSection(kind: .machine(machine), nodes: rows.map(SidebarNode.workspace))]
        let position = { (index: Int) in DropPosition(section: .machine(.local), index: index) }
        // Move "a" to after "c": remaining b c d, index 2 -> before d -> root 2.
        #expect(WorkspaceOrdering.shared.rootIndex(for: position(2), moving: [SidebarWorkspaceID("a")], in: sections) == 2)
        #expect(WorkspaceOrdering.shared.rootIndex(for: position(3), moving: [SidebarWorkspaceID("a")], in: sections) == 3)
        #expect(WorkspaceOrdering.shared.rootIndex(for: position(0), moving: [SidebarWorkspaceID("d")], in: sections) == 0)
    }
}
