@testable import CmuxNextApp
import CmuxNextControl
import CmuxNextPalette
import CmuxNextSidebar
import Foundation
import Testing

/// Go to Workspace's groups, panes and tabs from the topology and the
/// sidebar's groups, and where choosing a group goes.
@MainActor
struct PaletteNavigationEntriesTests {
    private static func topology() -> ControlTopology {
        var topology = ControlTopology()
        var chat = ControlTabInfo(id: "chat", surface: "3", kind: "conversation", title: "Fix CI")
        chat.agentSessionID = "acp-1"
        var notes = ControlTabInfo(id: "notes", surface: "4", kind: "conversation", title: "README.md")
        notes.page = "markdown"
        var agent = ControlTabInfo(id: "claude", surface: "5", kind: "terminal", title: "claude", cwd: "/srv/api")
        agent.agent = "claude"
        agent.agentHarnessSessionID = "0d8f6c1e-2b7a-4c55-9a51-7e2f4b1c9d30"
        let shell = ControlTabInfo(id: "shell", surface: "1", kind: "terminal", title: "zsh", cwd: "/srv/api")
        let docs = ControlTabInfo(id: "docs", surface: "2", kind: "browser", title: "Docs", url: "https://example.com")
        let left = ControlPaneInfo(id: "pane-l", handle: "10", selectedTabID: "docs", tabs: [shell, docs])
        let right = ControlPaneInfo(id: "pane-r", handle: "11", name: "Agents", tabs: [chat, notes])
        let lone = ControlPaneInfo(id: "pane-x", handle: "12", tabs: [agent])
        topology.workspaces = [
            ControlWorkspaceInfo(id: "ws-api", handle: "1", name: "api",
                                 screens: [ControlScreenInfo(id: "s1", handle: "1", panes: [left, right])]),
            ControlWorkspaceInfo(id: "ws-web", handle: "2", name: "web",
                                 screens: [ControlScreenInfo(id: "s2", handle: "2", panes: [lone])]),
        ]
        topology.focus = ControlFocus(paneID: "pane-l", tabID: "docs")
        return topology
    }

    private static let groups = [PaletteNavigationGroup(id: "grp-1", name: "Backend", color: .green, workspaceIDs: ["ws-api"])]

    @Test func everyGroupPaneAndTabIsAnEntryWithItsParents() {
        let used = Date(timeIntervalSince1970: 500)
        let entries = PaletteNavigationEntries.entries(Self.topology(), groups: Self.groups, lastActive: ["shell": used])
        #expect(entries.map(\.itemID) == ["group:grp-1", "pane:pane-l", "tab:shell", "tab:docs", "pane:pane-r", "tab:chat", "tab:notes",
                                          "tab:claude"])
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.itemID, $0) })

        #expect(byID["group:grp-1"]?.kind == .group(workspaceCount: 1))
        #expect(byID["group:grp-1"]?.color == .green)

        // A pane is named by its name, else its selected tab; it is found by its tabs' titles.
        #expect(byID["pane:pane-l"]?.title == "Docs")
        #expect(byID["pane:pane-l"]?.keywords == ["zsh", "Docs"])
        #expect(byID["pane:pane-l"]?.isCurrent == true)
        #expect(byID["pane:pane-l"]?.lastUsed == used)
        #expect(byID["pane:pane-r"]?.title == "Agents")

        #expect(byID["tab:shell"]?.workspaceTitle == "api")
        #expect(byID["tab:shell"]?.groupTitle == "Backend")
        #expect(byID["tab:shell"]?.cwd == "/srv/api")
        #expect(byID["tab:docs"]?.url == "https://example.com")
        #expect(byID["tab:docs"]?.isCurrent == true)
        #expect(byID["tab:claude"]?.groupTitle == nil)
        #expect(byID["tab:claude"]?.agent == "claude")
        // Copy Session ID: an acpmux chat's `cmux agent message` handle, a Claude terminal's own session UUID.
        #expect(byID["tab:chat"]?.sessionID == "acp:acp-1")
        #expect(byID["tab:claude"]?.sessionID == "0d8f6c1e-2b7a-4c55-9a51-7e2f4b1c9d30")
        #expect(byID["tab:shell"]?.sessionID == nil)
    }

    @Test func tabKindsAreTold() {
        let entries = PaletteNavigationEntries.entries(Self.topology(), groups: [], lastActive: [:])
        let kinds = Dictionary(uniqueKeysWithValues: entries.compactMap { entry -> (String, PaletteNavigationEntry.TabKind)? in
            guard case .tab(let kind) = entry.kind else { return nil }
            return (entry.id, kind)
        })
        #expect(kinds == ["shell": .terminal, "docs": .browser, "chat": .agentChat, "notes": .markdown, "claude": .terminal])
    }

    @Test func aLonePaneIsNotListedAndClosingTabsAreLeftOut() {
        let entries = PaletteNavigationEntries.entries(Self.topology(), groups: [], lastActive: [:], closing: ["notes"])
        #expect(!entries.contains { $0.itemID == "pane:pane-x" })
        #expect(!entries.contains { $0.itemID == "tab:notes" })
        #expect(entries.first { $0.itemID == "pane:pane-r" }?.keywords == ["Fix CI"])
    }

    // MARK: Group to first workspace

    @Test func aCollapsedGroupOpensAndShowsItsFirstReadyWorkspace() {
        let creating = SidebarWorkspace(id: .init("new"), title: "new", rowState: .creating)
        let first = SidebarWorkspace(id: .init("first"), title: "first")
        let second = SidebarWorkspace(id: .init("second"), title: "second")
        let group = SidebarGroup(id: .init("g"), name: "G", isCollapsed: true, workspaces: [creating, first, second])
        #expect(WorkspaceGroupFocus.plan(for: group) == .init(expands: true, workspace: .init("first"), reopens: false))
    }

    @Test func anOpenGroupShowsItsFirstWorkspaceWithoutToggling() {
        let group = SidebarGroup(id: .init("g"), name: "G", workspaces: [SidebarWorkspace(id: .init("a"), title: "a")])
        #expect(WorkspaceGroupFocus.plan(for: group) == .init(expands: false, workspace: .init("a"), reopens: false))
    }

    @Test func anEmptySavedGroupReopensAndAnEmptyGroupDoesNothing() {
        let saved = SidebarGroup(id: .init("g"), name: "G", isCollapsed: true, isPinned: true, workspaces: [])
        #expect(WorkspaceGroupFocus.plan(for: saved) == .init(expands: false, workspace: nil, reopens: true))
        let empty = SidebarGroup(id: .init("h"), name: "H", workspaces: [])
        #expect(WorkspaceGroupFocus.plan(for: empty) == .init(expands: false, workspace: nil, reopens: false))
    }
}
