import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// Review note 1 of #30279 (comment 6554528009): a read of every live pty tab's process (the close question, the quit
/// facts) named a Ctrl-` stand-in tab too. The request boundary refuses a stand-in (rule b) and the person saw "This pane
/// is still opening" for a read they never asked for, while their terminal was opening fine.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct StandInReadRefusalTests {
    @Test func readsOfEveryTerminalWhileACtrlBacktickStandInShowsRaiseNoRefusal() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let pid = try #require(services.daemon.identity?.pid)
            let content = try #require(services.windows.active?.workspaceContent)
            let pane = try #require(content.focusedPane)
            let shown = services.refusalHUD.shownCount
            // The daemon answers nothing while the reads run, so the Ctrl-` tab is still its stand-in.
            #expect(kill(pid, SIGSTOP) == 0)
            var resumed = false
            defer { if !resumed { kill(pid, SIGCONT) } }
            let work = services.registry.capturingWork {
                _ = services.registry.perform("newSurface", invocation: ActionInvocation(origin: .user))
            }
            let standIn = try #require(pane.pane.tabs.first { ProvisionalTab.isProvisional(surface: $0.surface) && $0.kind == .pty },
                                       "the Ctrl-` tab shows no stand-in in its turn")
            // Reads that the boundary refuses on a stand-in end at once, before any daemon answer.
            async let programs = DestructiveConfirmation.runningPrograms(bySurface: pane.pane.tabs, on: services.daemon)
            async let quit = QuitFactsReader.read(services)
            try await Task.sleep(for: .milliseconds(300)) // test-only: the refused reads report on the next frame
            #expect(kill(pid, SIGCONT) == 0)
            resumed = true
            let asked = await programs
            _ = await quit
            for task in work { _ = await task.value }
            try await PasswordManagerRouteTests.until({ !ProvisionalTab.isProvisional(surface: standIn.surface) || services.daemon.store.tabsBySurface[standIn.surface] == nil },
                                                      report: { "the Ctrl-` stand-in was never taken over" })
            #expect(services.refusalHUD.shownCount == shown,
                    "a read of every terminal showed a refusal: \(services.refusalHUD.history.suffix(3))")
            #expect(asked[standIn.surface].map { $0 == nil } ?? true, "the stand-in reported a running program: \(String(describing: asked[standIn.surface]))")
        }
    }
}
