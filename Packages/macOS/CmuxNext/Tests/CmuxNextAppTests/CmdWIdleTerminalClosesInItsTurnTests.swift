import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs
import Foundation
import Testing

/// SHORTCUT LATENCY SL-3 (SHORTCUT FRAMES F6, 2026-11-02): Cmd-W on a live terminal showed its first changed frame
/// 4 to 6 display refreshes after the key (120 Hz, real HID): the close asked the daemon what the terminal runs after
/// the key (`TabCloseGuard`, the close warning), and the tab left only when that read answered, on a later turn.
/// Now the tab leaves the strip in the key's own turn while its terminal stays alive; the daemon's read then decides:
/// nothing runs, the close goes to the daemon; a program runs, the tab comes back in place and the question shows.
/// A program is never ended without the question (lead, #31875: a resumed editor closed with no question is data loss),
/// whatever the shell reported before the key: the harness's /bin/sh sends no OSC 133 C, as a program started from a
/// line-editor key binding (`fg`, `$EDITOR`) does not.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdWIdleTerminalClosesInItsTurnTests {
    @Test func cmdWOnAnIdleTerminalLeavesInTheKeysTurnAndClosesAfterTheRead() async throws {
        try await Self.withFocusedTerminal { t in
            let performed = t.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
            #expect(performed)
            #expect(!t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id), "the tab did not leave the strip in the key's turn")
            // The read finds the shell only: the close goes to the daemon, and the tab never comes back.
            try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(t.tab.id) && t.store.closingTabIDs.isEmpty },
                                            report: { "waiting for the close: asking \(TabCloseGuard.asking), closing \(t.store.closingTabIDs)" })
            #expect(!t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id), "an idle terminal's tab came back after its close")
            #expect(Self.question() == nil, "an idle terminal's close asked")
        }
    }

    /// (a) A stopped program resumed with `fg` from a key binding sends no OSC 133 C: the shell's prompt report still
    /// stands, and anything read at that prompt says "no program". Cmd-W must still ask, and the program must live.
    @Test func cmdWAfterFgFromAKeyBindingAsks() async throws {
        try await Self.withFocusedTerminal { t in
            try await Self.input("sleep 600\r", t)
            try await Self.waitRunning("sleep", t)
            try await Self.input("\u{1A}", t) // Ctrl-Z: stopped, the shell is back in front
            try await Self.waitRunning(nil, t)
            try await Self.input("printf '\\033]133;A\\007'\r", t) // the prompt's report, as an integrated shell sends it
            try await PinnedPageTests.until({ t.tab.promptSinceMs != nil }, report: { "no prompt reached the store" })
            try await Self.settle()
            try await Self.input("fg\r", t) // resumed with no OSC 133 C
            try await Self.waitRunning("sleep", t)
            try await Self.cmdWAsks(t)
        }
    }

    /// (b) A command started just before Cmd-W: its OSC 133 C has not reached the store (here it sends none), so the
    /// prompt's report still stands. Cmd-W must still ask, and the program must live.
    @Test func cmdWRightAfterACommandStartedAsks() async throws {
        try await Self.withFocusedTerminal { t in
            try await Self.input("printf '\\033]133;A\\007'\r", t)
            try await PinnedPageTests.until({ t.tab.promptSinceMs != nil }, report: { "no prompt reached the store" })
            try await Self.settle()
            try await Self.input("sleep 600\r", t)
            try await Self.waitRunning("sleep", t)
            try await Self.cmdWAsks(t)
        }
    }

    // MARK: Fixture

    private struct Terminal {
        let services: AppServices
        let connection: DaemonConnection
        let store: DaemonStore
        let pane: PaneController
        let tab: TabModel
    }

    /// A focused live terminal in a pane that keeps another tab, its shell started.
    private static func withFocusedTerminal(_ body: (Terminal) async throws -> Void) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let paneModel = try #require(store.workspaces.first?.screens.first?.panes.first)
            let surface = try await connection.newTab(in: paneModel.handle).surface
            try await PinnedPageTests.until({ store.tab(surface: surface) != nil })
            let tab = try #require(store.tab(surface: surface))
            let pane = try #require(services.paneController(for: paneModel))
            try await PinnedPageTests.until({ pane.orderedIDs.map(\.rawValue).contains(tab.id) && pane.orderedIDs.count > 1 })
            pane.select(TabID(tab.id))
            try #require(services.windows.active?.focusedPane === pane, "the terminal's pane is not the focused one")
            try #require(TabCloseGuard.asks([tab], services: services), "the terminal close warning does not apply")
            let terminal = Terminal(services: services, connection: connection, store: store, pane: pane, tab: tab)
            try await Self.waitRunning(nil, terminal)
            defer { if let record = question() { _ = CmuxDialogCenter.shared.press(record.id, button: "cancel") } }
            try await body(terminal)
        }
    }

    private static func input(_ text: String, _ t: Terminal) async throws {
        _ = try await t.connection.request(SendInputRequest(surface: t.tab.surface, text: text))
    }

    /// Waits until the daemon names `program` as the terminal's foreground program (nil: its shell only).
    private static func waitRunning(_ program: String?, _ t: Terminal) async throws {
        var last = "no answer"
        for _ in 0..<100 {
            // Only an answer counts: a read that did not answer is not "its shell only".
            if let answer = await t.connection.readProcessInfo(t.tab.surface, timeout: .seconds(1)) {
                if answer.runningProgram == program { return }
                last = answer.runningProgram ?? "its shell only"
            }
            try await Task.sleep(for: .milliseconds(100)) // test harness polling the daemon
        }
        Issue.record("the terminal never ran \(program ?? "its shell only") in front (last: \(last))")
    }

    /// Room for anything the app reads at the prompt before the key (a test harness bound, not product timing).
    private static func settle() async throws { try await Task.sleep(for: .milliseconds(1_500)) }

    private static func question() -> CmuxDialogCenter.Record? {
        CmuxDialogCenter.shared.records.first { $0.spec.identifier == "cmux.dialog.confirmation" }
    }

    /// Cmd-W on the running program: the question shows, the tab is back in its strip, and the program still runs;
    /// Cancel keeps it.
    private static func cmdWAsks(_ t: Terminal) async throws {
        let performed = t.services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
        #expect(performed)
        try await PinnedPageTests.until({ question() != nil }, report: {
            "no close question: asking \(TabCloseGuard.asking), in strip \(t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id)), closing \(t.store.closingTabIDs)"
        })
        #expect(t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id), "the tab is not back in its strip while its question shows")
        try await Self.waitRunning("sleep", t)
        _ = CmuxDialogCenter.shared.press(try #require(question()).id, button: "cancel")
        try await PinnedPageTests.until({ !TabCloseGuard.asking.contains(t.tab.id) }, report: { "the cancelled close still asks" })
        #expect(t.pane.orderedIDs.map(\.rawValue).contains(t.tab.id), "Cancel did not keep the tab")
        try await Self.waitRunning("sleep", t)
    }
}
