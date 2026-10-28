import AppKit
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-28 (handoff/motion-cascade.md): "cmd w on last tab in workspace should have better close animation
/// (should just be same as cmd shift w animation, not animate closing the tab first, then the workspace)". One intent,
/// one animation: a Cmd-W that empties the workspace's only pane is that workspace's close, from the press's turn, as
/// Close Workspace (Cmd-Shift-W) does it: its row leaves the sidebar, the selection moves and the window shows the
/// next workspace in that turn. Before, the tab went, an empty pane stayed for a daemon round trip, and the workspace
/// left about three round trips later through the empty-workspace repair. Runs against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdWLastTabClosesWorkspaceTests {
    /// A second workspace whose one pane holds one tab, whatever Cmd-N opens on this Mac (a terminal or the New Tab
    /// page), shown in the active window.
    static func secondWorkspace(_ services: AppServices) async throws -> (window: WindowController, workspace: String, first: String) {
        let store = services.daemon.store
        let first = try #require(store.workspaces.first).id
        #expect(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
        try await PinnedPageTests.until({
            store.workspaces.count == 2 && services.windows.active?.state.workspaceID != first
                && (services.windows.active?.workspaceContent?.focusedPane?.orderedIDs.count ?? 0) == 1
        }, report: { "workspaces \(store.workspaces.count), shown \(String(describing: services.windows.active?.state.workspaceID))" })
        let window = try #require(services.windows.active)
        let content = try #require(window.workspaceContent)
        try #require(content.layoutModel.screens.reduce(0) { $0 + $1.layout.panes.count } == 1, "the new workspace shows more than one pane")
        return (window, try #require(window.state.workspaceID), first)
    }

    @Test func cmdWOnTheLastTabClosesTheWorkspaceInThePressTurn() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let (window, closing, first) = try await Self.secondWorkspace(services)

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            // The press's turn: the workspace closes as Close Workspace closes it.
            #expect(ClosingWorkspaces.shared.ids.contains(closing), "Cmd-W on the last tab did not close its workspace in its turn")
            #expect(window.state.workspaceID != closing, "the window still shows the closing workspace")

            try await PinnedPageTests.until({ store.workspaces.allSatisfy { $0.id != closing } }, report: { "the workspace was not closed" })
            #expect(services.windows.active === window, "the window closed with the workspace")
            #expect(store.workspaces.contains { $0.id == first }, "the other workspace closed too")
        }
    }

    /// audit-findings-1 C: the close offers "Workspace closed" with Undo for 5 s, and Cmd-Shift-T brings the workspace
    /// back, shown in the window.
    @Test func cmdWOnTheLastTabOffersUndoAndCmdShiftTReopensTheWorkspace() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let store = services.daemon.store
            let (window, closing, _) = try await Self.secondWorkspace(services)
            let nsWindow = try #require(window.window)

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            let toast = { CmuxToastCenter.shared.toasts(in: nsWindow).first { $0.id == "workspace-closed" } }
            try await PinnedPageTests.until({ toast() != nil }, report: {
                "no workspace close toast: \(CmuxToastCenter.shared.toasts(in: nsWindow).map { "\($0.id): \($0.message)" })"
            })
            let shown = try #require(toast())
            #expect(shown.message == "Workspace closed")
            #expect(shown.duration == .seconds(5))
            #expect(shown.action?.isUndo == true && shown.action?.title.hasPrefix("Undo") == true, "\(String(describing: shown.action))")

            try await PinnedPageTests.until({ store.workspaces.allSatisfy { $0.id != closing } }, report: { "the workspace was not closed" })
            let before = Set(store.workspaces.map(\.id))
            #expect(services.registry.perform("reopenClosedBrowserPanel", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({
                store.workspaces.contains { !before.contains($0.id) } && window.state.workspaceID.map { !before.contains($0) } == true
            }, report: { "Cmd-Shift-T did not bring the workspace back into the window: shown \(String(describing: window.state.workspaceID))" })
        }
    }

    /// audit-findings-1 C, hold-shortcuts-ux.md: key repeat never crosses into a workspace close. A held Cmd-W stops at
    /// the last tab; a new press closes the workspace.
    @Test func aHeldCmdWStopsAtTheLastTab() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let (window, closing, _) = try await Self.secondWorkspace(services)
            let pane = try #require(window.workspaceContent?.focusedPane)
            let repeatEvent = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                                            characters: "w", charactersIgnoringModifiers: "w", isARepeat: true, keyCode: 13))
            let dispatching = services.registry.dispatchingInputEvent
            services.registry.dispatchingInputEvent = { repeatEvent }
            services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
            services.registry.dispatchingInputEvent = dispatching
            #expect(!ClosingWorkspaces.shared.ids.contains(closing), "a key repeat closed the workspace")
            #expect(window.state.workspaceID == closing, "a key repeat left the workspace")
            #expect(pane.orderedIDs.count == 1, "a key repeat closed the last tab")

            #expect(services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
            #expect(ClosingWorkspaces.shared.ids.contains(closing), "a new press did not close the workspace")
        }
    }

    /// audit-findings-1 C: closing the last workspace of a window keeps the window and shows Home there (not closed,
    /// not empty). Close Workspace is the close Cmd-W on the last tab runs.
    @Test func closingTheLastWorkspaceOfAWindowShowsHomeThere() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            services.home.ensureHomeWorkspace(connection)
            try await PinnedPageTests.until({ services.home.homeWorkspace != nil }, within: .seconds(60),
                                            report: { "no home workspace: \(services.home.homeWorkspaceStep)" })
            let home = try #require(services.home.homeWorkspace).id
            let count = store.workspaces.count
            #expect(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ store.workspaces.count == count + 1 }, report: { "no new workspace" })
            let closing = try #require(store.workspaces.first { $0.id != home && services.windows.active?.state.workspaceID == $0.id }?.id,
                                       "the new workspace is not shown")
            let window = try #require(services.windows.openWindow(workspaces: [closing]))
            let id = window.state.id
            try #require(services.windows.registry.members(of: id) == [closing], "\(services.windows.registry.members(of: id))")

            #expect(services.registry.perform("closeWorkspace", invocation: ActionInvocation(closingRow: closing)))
            #expect(window.state.workspaceID == home, "the window does not show Home in the press's turn")
            try await PinnedPageTests.until({ store.workspaces.allSatisfy { $0.id != closing } }, report: { "the workspace was not closed" })
            #expect(services.windows.registry.value.window(id)?.isOpen == true, "the window closed with its last workspace")
            #expect(services.windows.registry.members(of: id) == [home], "\(services.windows.registry.members(of: id))")
            #expect(window.state.workspaceID == home)

            // Home cannot be closed: Close Workspace on it does nothing.
            services.registry.perform("closeWorkspace", invocation: ActionInvocation(closingRow: home))
            #expect(!ClosingWorkspaces.shared.ids.contains(home) && window.state.workspaceID == home, "Close Workspace closed Home")
        }
    }
}

/// Close Workspace's question covers what a tab close of its terminals asks. A unit test of the question, no daemon.
@MainActor @Suite(.serialized)
struct CloseWorkspaceAgentQuestionTests {
    /// Close Workspace asks what the tab close of its terminals would ask: an agent at work in one, with
    /// `app.warnBeforeClosingAgentSession` (its default, on), so Cmd-W through the workspace close loses no question
    /// (review of 5141e93507e). The same holds for Cmd-Shift-W.
    @Test func closeWorkspaceAsksAboutAWorkingAgentAsTheTabCloseDoes() async throws {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, tabResourceID: "tab_1", title: "~")])
        let workspace = WorkspaceModel(WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])]))
        let tab = try #require(workspace.screens.first?.panes.first?.tabs.first)
        try #require(tab.kind == .pty && !tab.dead, "the fixture's tab is not a live terminal")
        tab.agent = AgentStatus(surface: 1, state: .working, agent: "claude")
        let services = AppServices(environment: AppEnvironment.current([:]))
        let prompt = await WorkspaceBulkClose.prompt([(workspace, services.daemon)], warn: false, warnAgent: true)
        #expect(prompt?.suppresses == CmuxConfigSnapshot.warnBeforeClosingAgentSessionPath, "no agent question: \(String(describing: prompt))")
        #expect(await WorkspaceBulkClose.prompt([(workspace, services.daemon)], warn: false, warnAgent: false) == nil)
    }
}
