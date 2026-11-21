import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
@testable import CmuxNextDaemon
import CmuxNextDesign
import Foundation
import Testing

/// Undo Layout Change on a split runs at once (Leo 2026-11-17, the ceremony audit: "go remove this ... bullshit
/// ceremony"). It used to refuse with "Undo closes 1 pane(s). Run Undo Layout Change again to confirm." and run only
/// on a second press. Now it asks only as a tab close does (`TabCloseGuard`): while a program runs in a pane it closes.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct UndoLayoutClosesPanesTests {
    @Test func undoOfASplitWithAnIdleShellRunsAtOnce() async throws {
        try await AppHarnessWindows.withApp { services, _ in
            let (content, made) = try await Self.split(services)
            #expect(services.registry.perform("layout.undo", invocation: ActionInvocation(origin: .user)), "the undo was refused")
            try await PinnedPageTests.until({ content.panes[made] == nil }, report: { "the first Undo did not take the split back" })
            #expect(PinnedPageTests.closeQuestion(of: services) == nil, "an undo that closes an idle shell asked")
        }
    }

    @Test func undoOfASplitRunningAProgramAsksAndCancelKeepsIt() async throws {
        try await AppHarnessWindows.withApp { services, connection in
            let (content, made) = try await Self.split(services)
            let surface = try #require(content.panes[made]?.pane.tabs.first?.surface)
            _ = try await connection.request(SendInputRequest(surface: surface, text: "sleep 600\r"))
            try await Self.waitRunning("sleep", surface, connection)
            #expect(services.registry.perform("layout.undo", invocation: ActionInvocation(origin: .user)), "the undo was refused")
            try await PinnedPageTests.until({ PinnedPageTests.closeQuestion(of: services) != nil }, report: { "no question while sleep runs" })
            _ = CmuxDialogCenter.shared.press(try #require(PinnedPageTests.closeQuestion(of: services)).id, button: "cancel")
            try await Task.sleep(for: .milliseconds(500)) // test harness bound: a wrong undo would land by now
            #expect(content.panes[made] != nil, "Cancel did not keep the split")
        }
    }

    /// Splits the focused pane and waits for the daemon's pane to show and take the focus.
    private static func split(_ services: AppServices) async throws -> (WorkspaceContentController, LayoutPaneID) {
        _ = try await NewTabOpenFramesTests.focusedPane(services)
        let controller = try #require(services.windows.active)
        let content = try #require(controller.workspaceContent)
        let before = Set(content.panes.keys)
        #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
        try await PinnedPageTests.until({
            content.panes.first { !before.contains($0.key) }.map { !$0.value.pane.tabs.isEmpty
                && $0.value.pane.handle.rawValue < ProvisionalPane.firstHandle } ?? false
        }, report: { "the split never showed the daemon's pane" })
        return (content, try #require(content.panes.keys.first { !before.contains($0) }))
    }

    private static func waitRunning(_ program: String, _ surface: SurfaceID, _ connection: DaemonConnection) async throws {
        for _ in 0..<100 {
            if await connection.readProcessInfo(surface, timeout: .seconds(1))?.runningProgram == program { return }
            try await Task.sleep(for: .milliseconds(100)) // test harness polling the daemon
        }
        Issue.record("the terminal never ran \(program) in front")
    }
}
