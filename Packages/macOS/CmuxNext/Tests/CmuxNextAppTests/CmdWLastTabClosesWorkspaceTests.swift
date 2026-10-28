import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar
import Foundation
import Testing

/// Lawrence 2026-10-28 ("Cmd-W on the last tab of a workspace needs to be better"; audit-findings-1.md C): Cmd-W on
/// the last tab of the last pane closes the WORKSPACE in the press's own turn: its row leaves the sidebar and the
/// window shows the neighbour workspace in that turn, a toast "Workspace closed" offers Undo (Cmd-Shift-T) for 5 s,
/// and Cmd-Shift-T brings the workspace back. A held Cmd-W never crosses into it (only a new press closes the
/// workspace). The last workspace of a window gives way to Home: the window is not closed and does not show an empty
/// workspace. Runs on a same-tree daemon with zsh terminals and the close warning off (no question).
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdWLastTabClosesWorkspaceTests {
    static let settings = #"{"app":{"warnBeforeClosingTab":false}}"#

    @Test func cmdWOnTheLastTabClosesTheWorkspaceInThePressTurnWithAnUndoToast() async throws {
        try await CmdWSpamTests.withZshApp(settings: Self.settings) { services, _ in
            let (controller, first, made) = try await Self.secondWorkspace(services)
            let window = try #require(controller.window)
            let name = made.name

            #expect(CmdWSpamTests.press(services, repeat: false))
            // In the press's own turn: the row is closing, the window shows the neighbour.
            #expect(ClosingWorkspaces.shared.ids.contains(made.id), "the workspace's row did not leave in the press's turn")
            #expect(controller.state.workspaceID == first, "the window shows \(String(describing: controller.state.workspaceID)), not the neighbour \(first)")
            try await PinnedPageTests.until({ services.daemon.store.workspace(id: made.id) == nil }, report: { "the daemon kept the workspace" })
            try await PinnedPageTests.until({ CmuxToastCenter.shared.toasts(in: window).contains { $0.id == WorkspaceClosedToast.id } },
                                            report: { "no Workspace closed toast: \(CmuxToastCenter.shared.toasts(in: window).map(\.id))" })
            let toast = try #require(CmuxToastCenter.shared.toasts(in: window).first { $0.id == WorkspaceClosedToast.id })
            #expect(toast.duration == .seconds(5))
            #expect(toast.action?.isUndo == true)

            // Cmd-Shift-T brings it back.
            #expect(services.registry.perform("reopenClosedBrowserPanel", invocation: ActionInvocation(origin: .user)))
            try await PinnedPageTests.until({ services.daemon.store.workspaces.contains { $0.name == name } },
                                            report: { "Cmd-Shift-T did not reopen \(name): \(services.daemon.store.workspaces.map(\.name))" })
        }
    }

    /// Key repeat never crosses the boundary: a held Cmd-W on the workspace's last tab closes nothing; a new
    /// press then closes the workspace.
    @Test func aHeldCmdWNeverClosesTheWorkspaceAndANewPressDoes() async throws {
        try await CmdWSpamTests.withZshApp(settings: Self.settings) { services, _ in
            let (controller, _, made) = try await Self.secondWorkspace(services)
            for _ in 0..<5 { CmdWSpamTests.press(services, repeat: true) }
            try await Task.sleep(for: .milliseconds(500))
            #expect(services.daemon.store.workspace(id: made.id) != nil, "a key repeat closed the workspace")
            #expect(controller.state.workspaceID == made.id)
            CmdWSpamTests.press(services, repeat: false)
            try await PinnedPageTests.until({ services.daemon.store.workspace(id: made.id) == nil }, report: { "the new press did not close it" })
        }
    }

    /// The window's last workspace: Cmd-W on its last tab shows Home; the window stays open and never shows an
    /// empty workspace. Cmd-W on Home closes nothing.
    @Test func cmdWOnTheLastWorkspacesLastTabShowsHome() async throws {
        try await CmdWSpamTests.withZshApp(settings: Self.settings) { services, _ in
            try await PinnedPageTests.until({ services.home.homeWorkspace != nil }, within: .seconds(60), report: { services.home.homeWorkspaceStep })
            let home = try #require(services.home.homeWorkspace)
            let controller = try #require(services.windows.active)
            let shown = try #require(controller.state.workspaceID)
            try #require(shown != home.id, "the window shows Home already")
            let content = try #require(controller.workspaceContent)
            try #require(content.panes.count == 1 && content.panes.values.first?.orderedIDs.count == 1, "the restore made more than one tab")

            #expect(CmdWSpamTests.press(services, repeat: false))
            #expect(controller.state.workspaceID == home.id, "the window shows \(String(describing: controller.state.workspaceID)), not Home, in the press's turn")
            try await PinnedPageTests.until({ services.daemon.store.workspace(id: shown) == nil }, report: { "the daemon kept the workspace" })
            try await Task.sleep(for: .milliseconds(500))
            #expect(services.windows.controllers.contains { $0 === controller } && controller.window?.isVisible != false, "the window closed")
            #expect(controller.state.workspaceID == home.id)

            // Cmd-W on Home: nothing closes.
            CmdWSpamTests.press(services, repeat: false)
            try await Task.sleep(for: .milliseconds(300))
            #expect(services.home.homeWorkspace?.id == home.id && controller.state.workspaceID == home.id)
        }
    }

    // MARK: Helpers

    /// A second workspace made as Cmd-N makes it (shown, one terminal tab, at its prompt), and the first one's id.
    static func secondWorkspace(_ services: AppServices) async throws -> (WindowController, String, WorkspaceModel) {
        let controller = try #require(services.windows.active)
        let first = try #require(controller.state.workspaceID)
        let before = Set(services.daemon.store.workspaces.map(\.id))
        #expect(services.registry.perform("newTab", invocation: ActionInvocation(origin: .user)))
        func made() -> WorkspaceModel? {
            services.daemon.store.workspaces.first { !before.contains($0.id) && $0.screens.flatMap(\.panes).flatMap(\.tabs).count == 1 }
        }
        try await PinnedPageTests.until({ made() != nil && controller.state.workspaceID == made()?.id && controller.workspaceContent?.panes.count == 1 },
                                        within: .seconds(30), report: { "Cmd-N made no shown workspace with one tab" })
        let workspace = try #require(made())
        try await PinnedPageTests.until({ workspace.screens.flatMap(\.panes).flatMap(\.tabs).first?.promptSinceMs != nil }, within: .seconds(30),
                                        report: { "the new terminal never reached its prompt" })
        return (controller, first, workspace)
    }
}
