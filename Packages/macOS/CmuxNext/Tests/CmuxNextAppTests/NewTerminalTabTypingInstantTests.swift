import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// Toggle Terminal and Chat on a chat no terminal runs (mid-turn too) opens a terminal that types
/// `acpmux resume-here RUN` (TerminalChatHandler.resume). A new terminal tab that types its own text
/// took the waiting path: nothing showed until the daemon's `new-tab` answered (a round trip, 114 ms p50 /
/// 660 ms p95 on a loaded Mac when Ctrl-` measured it). Leo, 2026-11-12: terminal and GUI are two live views
/// of one session, instant both ways, mid-turn. Such a tab shows its stand-in in the call's turn, as Ctrl-`
/// does, and the text still runs in the daemon's terminal once it exists.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTerminalTabTypingInstantTests {
    @Test func aTerminalThatTypesItsTextShowsInTheCallsTurnAndRunsTheText() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            let content = try #require(services.windows.active?.workspaceContent)
            let pane = try #require(content.focusedPane, "the test window has no focused pane")
            try #require(services.daemon.supports(DaemonCapability.terminalPlacementEnv.rawValue), "the daemon takes no optimistic create")
            let pid = try #require(services.daemon.identity?.pid)
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent("typed-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: marker) }

            // The daemon answers nothing until the call's turn ended: whatever shows now showed without it.
            #expect(kill(pid, SIGSTOP) == 0)
            var resumed = false
            defer { if !resumed { kill(pid, SIGCONT) } }
            let work = services.registry.capturingWork {
                pane.newTerminalTab(typing: "touch '\(marker.path)'\r")
            }
            let shown = pane.pane.tabs.first { $0.kind == .pty && ProvisionalTab.isProvisional(surface: $0.surface) }
            #expect(shown != nil, "no terminal showed in the call's turn: \(pane.pane.tabs.map { "\($0.kind) \($0.surface.rawValue)" })")
            #expect(shown.map { pane.stripModel.selectedID?.rawValue == $0.id } == true, "the new terminal is not the selected tab")
            #expect(kill(pid, SIGCONT) == 0)
            resumed = true

            for task in work { if let failure = await task.value { Issue.record("the creation failed: \(failure.message)") } }
            // The daemon's terminal took the stand-in's place, selected, and ran the typed line.
            try await PasswordManagerRouteTests.until({
                pane.pane.tabs.contains { $0.kind == .pty && !ProvisionalTab.isProvisional(surface: $0.surface) && pane.stripModel.selectedID?.rawValue == $0.id }
            }, report: { "the daemon's terminal is not selected: \(pane.pane.tabs.map { "\($0.kind) \($0.surface.rawValue)" })" })
            try await PasswordManagerRouteTests.until({ FileManager.default.fileExists(atPath: marker.path) },
                                                      report: { "the typed line never ran in the new terminal" })
        }
    }
}
