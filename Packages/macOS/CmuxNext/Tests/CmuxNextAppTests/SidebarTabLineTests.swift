import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-27, on the tab rows listed under a workspace: "look at what's redundant and look at what's
/// useful ... not only does it show, well, you have Claude running here and another Claude running there, and
/// they're both titled this and that, but also ... a little bit more metadata". His screenshot: each lane
/// workspace listed "~" and "gcp-codex-lane-1/rail-jump-final" under "rail-jump-final".
@MainActor @Suite(.serialized)
struct SidebarTabLineTests {
    private static func tab(_ title: String, kind: SidebarTabKind = .terminal, folder: String? = nil, agent: String? = nil,
                            words: String? = nil, host: String? = nil) -> SidebarTab {
        var tab = SidebarTab(id: TabID(title), title: title, kind: kind)
        (tab.folder, tab.agent, tab.words, tab.host) = (folder, agent, words, host)
        return tab
    }

    private static func line(_ tab: SidebarTab, _ look: SidebarTabLineLook = .detail, workspace: String = "rail-jump-final") -> SidebarTabLine {
        var tab = tab
        tab.workspaceName = workspace
        return SidebarTabLine.make(tab, look: look, terminalName: "Terminal")
    }

    @Test func aBareHomeFolderNamesWhatRunsThere() {
        #expect(Self.line(Self.tab("~", folder: "~")) == SidebarTabLine(name: "Terminal", detail: nil))
        // A folder other than home is a fact the row does not say.
        #expect(Self.line(Self.tab("~/src/cmux", folder: "~/src/cmux")) == SidebarTabLine(name: "Terminal", detail: "~/src/cmux"))
    }

    @Test func theWorkspaceNameIsNotRepeated() {
        #expect(Self.line(Self.tab("gcp-codex-lane-1/rail-jump-final")).name == "gcp-codex-lane-1")
        #expect(Self.line(Self.tab("rail-jump-final: build")).name == "build")
        #expect(Self.line(Self.tab("Rail-Jump-Final")).name == "Terminal")
        #expect(Self.line(Self.tab("rail-jump-final", kind: .agentChat, agent: "Claude Code")) == SidebarTabLine(name: "Claude Code", detail: nil))
        // A title that only contains the name elsewhere keeps it.
        #expect(Self.line(Self.tab("fix rail-jump-final tests")).name == "fix rail-jump-final tests")
    }

    @Test func twoClaudeChatsSayWhichIsWhich() {
        let a = Self.line(Self.tab("Review the peer list", kind: .agentChat, folder: "~", agent: "Claude Code"))
        let b = Self.line(Self.tab("Prune DerivedData", kind: .agentChat, folder: "~", agent: "Claude Code", words: "Running tests"))
        #expect(a == SidebarTabLine(name: "Review the peer list", detail: "Claude Code"))
        // The program's own status words say more than the agent's name.
        #expect(b == SidebarTabLine(name: "Prune DerivedData", detail: "Running tests"))
    }

    @Test func pagesNameTheirHost() {
        #expect(Self.line(Self.tab("Pull requests", kind: .browser, host: "github.com")).detail == "github.com")
    }

    @Test func everyLook() {
        let chat = Self.tab("Prune DerivedData", kind: .agentChat, folder: "~", agent: "Claude Code", words: "Running tests")
        #expect(Self.line(Self.tab("~", folder: "~"), .plain) == SidebarTabLine(name: "~", detail: nil))
        #expect(Self.line(chat, .clean) == SidebarTabLine(name: "Prune DerivedData", detail: nil))
        #expect(Self.line(chat, .statusFirst) == SidebarTabLine(name: "Running tests", detail: "Prune DerivedData"))
        // Without status words the status-first look reads as the detail look.
        #expect(Self.line(Self.tab("~", folder: "~"), .statusFirst) == SidebarTabLine(name: "Terminal", detail: nil))
        #expect(SidebarTunables.tabLines.defaultValue == .detail)
    }

    /// The row draws the line: the name, the quieter detail after it, and the tab's own status on the
    /// trailing column (spoken too); the plain look draws the title as before. One live row follows a change
    /// of the look (`SidebarTunablesWatch`).
    @Test func theRowDrawsTheLine() throws {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarTunables.tabLines.key
        defer {
            TunableStore.shared.set(key, nil)
            SidebarTunablesWatch.shared.changed()
        }
        let workspace = WorkspaceID("ws-lines")
        var chat = Self.tab("Prune DerivedData", kind: .agentChat, agent: "Claude Code")
        (chat.state, chat.workspaceName) = (.working, "rail-jump-final")
        let rowKey = SidebarRowKey.tab(workspace, chat.id)
        let row = SidebarRow(key: rowKey, y: 0, height: 24, section: .machine(.local), workspace: workspace, siblingIndex: 0,
                             isLastInGroup: true, isCollapsed: false, childCount: 1)
        chat.brand = "claude"
        let view = SidebarTabRowView(key: rowKey)
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        view.configure(chat, row: row)
        for look in SidebarTabLineLook.allCases {
            TunableStore.shared.set(key, look.tunableValue)
            SidebarTunablesWatch.shared.changed()
            view.layoutSubtreeIfNeeded()
            let expected = SidebarTabLine.make(chat, look: look, terminalName: "Terminal")
            let status = look == .plain ? nil : Strings.activity(.working)
            #expect(view.accessibilityLabel() == [expected.name, expected.detail, status].compactMap { $0 }.joined(separator: ", "), "\(look)")
            // The agent's mark takes the empty icon slot, and the debug rows name it as one.
            #expect(view.debugIcon == (look == .plain ? nil : "agentMark"), "\(look)")
        }
    }
}

/// The bridge maps each listed tab's facts with its row: its own status, its workspace's own name, and
/// the folder only where it differs from the workspace's (a folder every tab shares says nothing of one;
/// the capture mini's terminals all drew the same long path).
@MainActor
struct SidebarTabLineMappingTests {
    @Test func eachTabCarriesItsOwnFacts() throws {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [
            TabSnapshot(surface: 1, terminalResourceID: "term_1", cwd: "/srv/lane"),
            TabSnapshot(surface: 2, terminalResourceID: "term_2", cwd: "/srv/lane/web"),
        ])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "rail-jump-final", screens: [screen])]))
        let line = #"{"type":"stream_item","item":{"kind":"snapshot","snapshot":{"terminals":[{"id":"term_2","extra":{"program_status":[{"id":"","state":"working","app":"cargo","updated_seq":"1"}]}}],"extra":{"state":{}}}}}"#
        store.session.apply(try #require(SessionStreamItem.decode(Data(line.utf8))), in: store)
        let workspace = try #require(store.workspaces.first)
        let tabs = SidebarMapping.shared.row(workspace, machine: .local).tabs
        try #require(tabs.count == 2)
        #expect(tabs.allSatisfy { $0.workspaceName == "rail-jump-final" })
        #expect(tabs[0].folder == "/srv/lane" && tabs[0].sharesWorkspaceFolder)
        #expect(tabs[1].folder == "/srv/lane/web" && !tabs[1].sharesWorkspaceFolder)
        // The workspace's folder is no detail, and a title that only names it reads as untitled.
        var shared = tabs[0]
        shared.title = "/srv/lane"
        #expect(SidebarTabLine.make(shared, look: .detail, terminalName: "Terminal") == SidebarTabLine(name: "Terminal", detail: nil))
        #expect(SidebarTabLine.make(tabs[1], look: .detail, terminalName: "Terminal").detail == "/srv/lane/web")
        #expect(tabs[0].state == .idle)
        #expect(tabs[1].state == .working(progress: nil))
    }
}
