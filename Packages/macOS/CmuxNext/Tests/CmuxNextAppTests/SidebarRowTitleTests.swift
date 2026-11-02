import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-26 on the sidebar's workspace row: "the name of the workspace can kind of be
/// considered the root ... So then you have a workspace name and then you have the tab name, and
/// they can be shown together on the sidebar, potentially." Debug Settings `sidebar.rowTitle`
/// picks the workspace alone (the default), Workspace › focused tab, the focused tab alone, or
/// every tab; `sidebar.rowTitleSingleChat` lets a one-chat workspace show the chat's name.
@MainActor @Suite(.serialized) struct SidebarRowTitleTests {
    private static func workspace(_ name: String = "Sidebar breadcrumb", tabs: [(String, SidebarTabKind)], focused: Int?) -> SidebarWorkspace {
        let made = tabs.enumerated().map { SidebarTab(id: TabID("t\($0.offset)"), title: $0.element.0, kind: $0.element.1) }
        var ws = SidebarWorkspace(id: WorkspaceID("ws"), title: name, kind: .harness, tabs: made)
        ws.focusedTab = focused.map { made[$0].id }
        return ws
    }

    private static let mixed = workspace(tabs: [("Draft the row", .agentChat), ("zsh", .terminal), ("Pull request", .browser)], focused: 1)

    @Test func theDefaultModeShowsTheWorkspaceNameAlone() {
        #expect(Self.mixed.rowTitle(.workspace) == "Sidebar breadcrumb")
        #expect(SidebarTunables.rowTitle.defaultValue == .workspace)
        #expect(SidebarTunables.rowTitleSingleChat.defaultValue == false)
    }

    @Test func eachModeComposesTheWorkspaceAndItsTabs() {
        #expect(Self.mixed.rowTitle(.breadcrumb) == "Sidebar breadcrumb › zsh")
        #expect(Self.mixed.rowTitle(.focusedTab) == "zsh")
        #expect(Self.mixed.rowTitle(.allTabs) == "Sidebar breadcrumb › zsh · Draft the row · Pull request", "the focused tab first")
    }

    @Test func theFocusedTabAloneStillSaysItsWorkspaceToVoiceOver() {
        #expect(Self.mixed.spokenRowTitle(.focusedTab) == "Sidebar breadcrumb › zsh")
        #expect(Self.mixed.spokenRowTitle(.breadcrumb) == Self.mixed.rowTitle(.breadcrumb))
        // An inherited chat name says its workspace too, in every mode (review of #25808).
        let chat = Self.workspace("workspace-3", tabs: [("Write the release notes", .agentChat)], focused: 0)
        for mode in SidebarRowTitleMode.allCases {
            #expect(chat.spokenRowTitle(mode, inheritsSingleChat: true) == "workspace-3 › Write the release notes", "\(mode)")
        }
    }

    /// A tab whose name only starts with the workspace's does not say the workspace (review of #25808).
    @Test func aTabThatStartsWithTheWorkspaceNameDoesNotNameIt() {
        let ws = Self.workspace("Project", tabs: [("Project setup", .terminal)], focused: 0)
        #expect(!ws.namesWorkspace(ws.rowTitle(.focusedTab)))
        #expect(ws.spokenRowTitle(.focusedTab) == "Project › Project setup")
        #expect(ws.namesWorkspace(ws.rowTitle(.breadcrumb)))
        #expect(ws.namesWorkspace(ws.rowTitle(.workspace)))
    }

    /// Automatic names follow the focused chat's title (cmux#25416): the crumb never says it twice.
    @Test func aTabNamedLikeItsWorkspaceIsNotRepeated() {
        let ws = Self.workspace("Fix login", tabs: [("fix login ", .agentChat), ("zsh", .terminal)], focused: 0)
        #expect(ws.rowTitle(.breadcrumb) == "Fix login")
        #expect(ws.rowTitle(.allTabs) == "Fix login › zsh")
    }

    @Test func noFocusedTabOrAnEmptyNameKeepsTheWorkspaceName() {
        let none = Self.workspace(tabs: [], focused: nil)
        for mode in SidebarRowTitleMode.allCases { #expect(none.rowTitle(mode) == "Sidebar breadcrumb") }
        let blank = Self.workspace(tabs: [("  ", .terminal)], focused: 0)
        #expect(blank.rowTitle(.breadcrumb) == "Sidebar breadcrumb")
        #expect(blank.rowTitle(.focusedTab) == "Sidebar breadcrumb")
        // A placeholder's empty name draws the loading bar: it gains no crumbs.
        #expect(Self.workspace("", tabs: [("zsh", .terminal)], focused: 0).rowTitle(.breadcrumb) == "")
    }

    @Test func aOneChatWorkspaceInheritsTheChatNameOnlyWhenAsked() {
        let chat = Self.workspace("workspace-3", tabs: [("Write the release notes", .agentChat)], focused: 0)
        #expect(chat.rowTitle(.workspace) == "workspace-3")
        for mode in SidebarRowTitleMode.allCases {
            #expect(chat.rowTitle(mode, inheritsSingleChat: true) == "Write the release notes")
        }
        // A terminal, or a chat beside another tab, is not "only that one agent chat".
        #expect(Self.workspace("w", tabs: [("zsh", .terminal)], focused: 0).rowTitle(.workspace, inheritsSingleChat: true) == "w")
        #expect(Self.mixed.rowTitle(.workspace, inheritsSingleChat: true) == "Sidebar breadcrumb")
    }

    /// The mapped row's focused tab is the selected tab of its most recently focused pane.
    @Test func theMappedRowCarriesItsFocusedTab() throws {
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_1"),
                                              TabSnapshot(surface: 2, terminalResourceID: "term_2")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        let second = try #require(workspace.screens.first?.panes.first?.tabs.last)
        let row = SidebarMapping.shared.row(workspace, machine: .local, selectedTab: { _ in second.id })
        #expect(row.focusedTab == TabID(second.id))
        #expect(SidebarMapping.shared.row(workspace, machine: .local).focusedTab != nil, "the daemon's default tab without a selection")
    }

    /// The drawn row: its title label says the mode's name, and the preview section lists rows
    /// that exercise every mode.
    @Test func theRowDrawsTheChosenName() throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarTunables.rowTitle.key
        defer {
            TunableStore.shared.set(key, nil)
            SidebarTunablesWatch.shared.changed()
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        for mode in SidebarRowTitleMode.allCases {
            TunableStore.shared.set(key, mode.tunableValue)
            SidebarTunablesWatch.shared.changed()
            let sidebar = SidebarView(model: SidebarModel(sections: [SidebarSection(kind: .machine(machine), nodes: [.workspace(Self.mixed)])]),
                                      design: DesignSettings())
            sidebar.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
            sidebar.layoutSubtreeIfNeeded()
            sidebar.list.reload(animated: false)
            let row = try #require(sidebar.list.rowViews[.workspace(Self.mixed.id)] as? WorkspaceRowView)
            #expect(row.title.stringValue == Self.mixed.rowTitle(mode), "\(mode)")
        }
        let preview = SidebarSection.rowTitlePreview().flatMap(\.workspaces)
        #expect(preview.count == 5)
        #expect(preview.allSatisfy { $0.focusedTab != nil && $0.rowState == .placeholder })
    }
}
