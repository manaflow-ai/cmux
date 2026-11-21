import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs
import Foundation
import Testing

/// Two apps live in one test process when two suites that each make one run side by side (the CI shard that holds the
/// two Cmd-W close suites does that), and `CmuxDialogCenter.shared` is one for the process. A test must read the close
/// question of its own app's window: the first confirmation of the centre can be another app's, and a test that reads
/// that one sees a question while its own tab is not back, and then cancels a question it does not own (the pair of
/// Cmd-W suites was red that way at 6d6961b8e75c, CmdWIdleTerminalClosesInItsTurnTests.swift:440).
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CloseQuestionOwnWindowTests {
    @Test func anAppReadsOnlyTheCloseQuestionOfItsOwnWindow() async throws {
        try await PinnedPageTests.withApp { asking, connection in
            try await PinnedPageTests.withApp { other, _ in
                let store = asking.daemon.store
                let paneModel = try #require(store.workspaces.first?.screens.first?.panes.first)
                try await PinnedPageTests.until({ asking.paneController(for: paneModel) != nil }, report: { "the first pane has no controller" })
                let pane = try #require(asking.paneController(for: paneModel))
                let surface = try await connection.newTab(in: paneModel.handle).surface
                try await PinnedPageTests.until({ store.tab(surface: surface).map { pane.orderedIDs.map(\.rawValue).contains($0.id) } == true },
                                                report: { "the new terminal's tab is not in its strip" })
                let tab = try #require(store.tab(surface: surface))
                pane.select(TabID(tab.id))
                try #require(asking.windows.active?.focusedPane === pane, "the terminal's pane is not the focused one")
                try #require(TabCloseGuard.asks([tab], services: asking), "the terminal close warning does not apply")
                try await Self.runs(nil, surface, connection)
                _ = try await connection.request(SendInputRequest(surface: surface, text: "sleep 600\r"))
                try await Self.runs("sleep", surface, connection)
                defer { if let record = PinnedPageTests.closeQuestion(of: asking) { _ = CmuxDialogCenter.shared.press(record.id, button: "cancel") } }

                // Cmd-W on the running program in the first app: its question shows in its window.
                #expect(asking.registry.perform("closeTab", invocation: ActionInvocation(origin: .user)))
                try await PinnedPageTests.until({ PinnedPageTests.closeQuestion(of: asking) != nil }, report: {
                    "the app that asks reads no close question: asking \(TabCloseGuard.asking), closing \(store.closingTabIDs)"
                })
                // The second app closed nothing: it has no question, whatever the centre they share holds.
                #expect(PinnedPageTests.closeQuestion(of: other) == nil, "an app that asked nothing reads the close question of another app in its process")

                _ = CmuxDialogCenter.shared.press(try #require(PinnedPageTests.closeQuestion(of: asking)).id, button: "cancel")
                try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(tab.id) }, report: { "the cancelled close still asks" })
                #expect(pane.orderedIDs.map(\.rawValue).contains(tab.id), "Cancel did not keep the tab")
                #expect(PinnedPageTests.closeQuestion(of: asking) == nil, "the question still shows after Cancel")
            }
        }
    }

    /// Waits until the daemon names `program` as the foreground program of the terminal (nil: its shell only).
    private static func runs(_ program: String?, _ surface: SurfaceID, _ connection: DaemonConnection) async throws {
        var last = "no answer"
        for _ in 0..<100 {
            // Only an answer counts: a read that did not answer is not "its shell only".
            if let answer = await connection.readProcessInfo(surface, timeout: .seconds(1)) {
                if answer.runningProgram == program { return }
                last = answer.runningProgram ?? "its shell only"
            }
            try await Task.sleep(for: .milliseconds(100)) // test harness polling the daemon
        }
        Issue.record("the terminal never ran \(program ?? "its shell only") in front (last: \(last))")
    }
}
