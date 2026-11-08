import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import CmuxNextTabs
import Foundation
import Testing

/// An agent that drives the screen (Computer Use) or a browser shows on its workspace row, its tab and
/// its pane at a glance, without the `sidebar.presenceDots` prototype toggle (Lawrence 2026-11-07: "the
/// computer use/browser use indicator in workspaces needs to be better"). The indicator names the agent
/// and what it drives; quieter activity (editing, reading) stays behind the toggle.
@MainActor
struct AgentDriveIndicatorTests {
    /// One workspace with one terminal tab (surface 1) whose agent reports `activity`.
    static func workspace(_ activity: AgentPresence.Activity?) throws -> WorkspaceModel {
        _ = NSApplication.shared
        let store = DaemonStore()
        let pane = PaneSnapshot(id: 1, activeTab: 0, tabs: [TabSnapshot(surface: 1, terminalResourceID: "term_1")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        _ = store.apply(.agentPresenceChanged(AgentPresence(surface: 1, activity: activity, agent: "claude", session: "claude-1")))
        return try #require(store.workspaces.first)
    }

    @Test(arguments: [(AgentPresence.Activity.computerUse, SidebarPresence.Activity.computerUse),
                      (.browsing, .browsing)])
    func aDrivingAgentReachesItsRowWithTheDotsOff(_ activity: AgentPresence.Activity, _ shown: SidebarPresence.Activity) throws {
        let row = SidebarMapping.shared.row(try Self.workspace(activity), machine: .local)
        let drive = try #require(row.presence.first { $0.activity == shown }, "the row knows the agent drives")
        #expect(drive.id == "claude-1")
        #expect(drive.name != "?")
    }

    @Test func aDrivingAgentReachesItsTabWithTheDotsOff() throws {
        let workspace = try Self.workspace(.computerUse)
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        let item = TabItemMapping.shared.item(tab, fallbackTitle: "Terminal")
        #expect(item.presence?.colorKey == "claude-1", "the tab chip shows the agent that drives")
    }

    @Test func quieterActivityStaysBehindTheToggle() throws {
        let row = SidebarMapping.shared.row(try Self.workspace(.editing), machine: .local)
        #expect(row.presence.isEmpty)
    }
}
