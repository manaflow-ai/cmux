import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAgentCursorVisibility
import CmuxNextSettings
import Testing

/// Follow-ups to TOP-SECTION-ITEMS-ARE-PAGES.
/// - nxdog56: on a page, Cmd-W closes nothing, but debug.key named the
///   resolved action "closeTab" as if it ran. The router records that the
///   run was refused, and debug.key reports a refused action, not a run.
/// - The agent cursor: while the Home page shows, a tab of the store's home
///   workspace (the chief tab) is on screen in that page; while any page
///   shows, other workspaces' tabs still have their sidebar rows.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2))) struct TopPageKeyAndCursorTests {
    @Test func commandWOnAPageIsRecordedAsRefused() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let window = try #require(harness.window.window)
        let tabs = harness.tabCount
        try #require(TopPages.show(.home, services: harness.services, in: harness.window.state) != nil)
        let commandW = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(harness.services.keyRouter.interceptKeyDown(commandW, in: window), "Cmd-W stays a cmux shortcut on a page")
        let interception = try #require(harness.services.keyRouter.lastInterception)
        #expect(interception.action == "closeTab")
        #expect(interception.ran == false, "nothing closed: the run was refused")
        #expect(harness.tabCount == tabs)
        let verdict = DebugKey.verdict(interception)
        #expect(verdict["action"] == .null, "debug.key reports no action ran")
        #expect(verdict["refused_action"]?.stringValue == "closeTab")
    }

    @Test func aRunActionIsReportedAsTheAction() {
        let verdict = DebugKey.verdict((action: "newTab", window: "w", ran: true))
        #expect(verdict["action"]?.stringValue == "newTab")
        #expect(verdict["refused_action"] == nil)
    }

    @Test func theChiefTabIsOnScreenInTheHomePage() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        try await HomeShowActionTests.addHome(harness)
        let home = try #require(harness.services.daemon.store.workspaces.first { $0.kind == "home" })
        let tab = try #require(home.screens.first?.panes.first?.tabs.first)
        try #require(TopPages.show(.home, services: harness.services, in: harness.window.state) != nil)
        harness.window.window?.contentView?.layoutSubtreeIfNeeded()
        let snapshot = AgentCursorSnapshotBuilder(services: harness.services).snapshot(forTarget: tab.id)
        let entry = try #require(snapshot.windows.first { $0.id == harness.window.state.id })
        #expect(entry.shownWorkspace == home.id, "the Home page shows the home workspace's content")
        #expect(entry.panes.first?.frame != nil, "the cursor anchors in the page")
    }

    @Test func otherWorkspacesKeepTheirSidebarRowsUnderAPage() async throws {
        let harness = try await ViewChangePermissionTests.harness()
        defer { harness.stop() }
        let workspace = try #require(harness.window.state.workspaceID)
        let tab = try #require(harness.services.daemon.store.workspaces.first?.screens.first?.panes.first?.tabs.first)
        try #require(TopPages.show(.home, services: harness.services, in: harness.window.state) != nil)
        harness.window.window?.contentView?.layoutSubtreeIfNeeded()
        let snapshot = AgentCursorSnapshotBuilder(services: harness.services).snapshot(forTarget: tab.id)
        let entry = try #require(snapshot.windows.first { $0.id == harness.window.state.id })
        #expect(entry.shownWorkspace == nil, "a page shows no workspace")
        #expect(entry.sidebarRows[workspace] != nil, "the tab's workspace row anchors the cursor")
    }
}
