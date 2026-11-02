import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTabs
import Foundation
import Testing

/// SHORTCUT LATENCY SL-3 (SHORTCUT FRAMES F6, 2026-11-02): Cmd-W on a live terminal showed its first changed frame
/// 4 to 6 display refreshes after the key (120 Hz, real HID): the close asked the daemon what the terminal runs
/// (`TabCloseGuard`, the close warning) after the key, and the tab left only when that read answered, on a later turn.
/// A focused terminal sitting at its shell prompt, whose program was read before the key in that same shell state,
/// closes in the key's own turn: no read waits, and the tab is out of the strip when the handler returns.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct CmdWIdleTerminalClosesInItsTurnTests {
    @Test func cmdWOnAnIdleFocusedTerminalLeavesInTheKeysTurn() async throws {
        try await Self.withIdleFocusedTerminal { services, store, pane, tab in
            let performed = services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
            #expect(performed)
            #expect(!TabCloseGuard.reading.contains(tab.id), "Cmd-W waited for the daemon's read of the terminal")
            #expect(!pane.orderedIDs.map(\.rawValue).contains(tab.id), "the tab did not leave the strip in the key's turn")
            try await PinnedPageTests.until({ store.tab(surface: tab.surface) == nil },
                                            report: { "waiting for the daemon close: reading \(TabCloseGuard.reading), asking \(TabCloseGuard.asking)" })
        }
    }

    /// Review of #31875: the answer read at the prompt must not stand for a command that starts after it. A read made
    /// between the shell's OSC 133 C and the command's exec still sees the shell, and the command's state does not change
    /// until it ends, so that "no program" would hold for a whole build. Here the shell marks a command start (C) and
    /// stays in the foreground: exactly that read's answer. Cmd-W must still read at the key, and the tab stays until
    /// the daemon answers (the close question can show).
    @Test func cmdWAfterACommandStartedReadsAtTheKeyAgain() async throws {
        try await Self.withIdleFocusedTerminal { services, _, pane, tab in
            try await Self.mark("C", on: tab, services)
            try await PinnedPageTests.until({ tab.commandSinceMs != nil }, within: .seconds(10),
                                            report: { "no command start reached the store: command \(String(describing: tab.commandSinceMs))" })
            // Room for a read of the command's state, if the app made one (its read answers in milliseconds; a test
            // harness bound, not product timing): it must not, and no answer may stand for the running command.
            for _ in 0..<20 where services.terminalReadAhead.fresh([tab]) == nil { try await Task.sleep(for: .milliseconds(100)) }
            #expect(services.terminalReadAhead.fresh([tab]) == nil, "an answer stands for the running command")

            // The read is held, so what the key's turn decides is seen before the daemon answers.
            let hold = services.daemon.closeReadHold
            hold.arm()
            defer { hold.release() }
            let performed = services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
            #expect(performed)
            #expect(TabCloseGuard.reading.contains(tab.id), "Cmd-W on a terminal running a command did not ask the daemon")
            #expect(pane.orderedIDs.map(\.rawValue).contains(tab.id), "a terminal running a command left before its close question")
        }
    }

    /// The shell prints OSC 133 mark `kind` (A: a prompt starts, C: a command starts), as an integrated zsh, bash or fish
    /// does; the daemon reads it from the output and the store mirrors it (`extra.prompt`, `extra.busy`). The harness's
    /// /bin/sh has no integration of its own.
    private static func mark(_ kind: String, on tab: TabModel, _ services: AppServices) async throws {
        let connection = try #require(services.daemon.connection)
        _ = try await connection.request(SendInputRequest(surface: tab.surface, text: "printf '\\033]133;\(kind)\\007'\r"))
    }

    /// A focused live terminal at its prompt, read before the key (its answer is fresh).
    private static func withIdleFocusedTerminal(_ body: (AppServices, DaemonStore, PaneController, TabModel) async throws -> Void) async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let paneModel = try #require(store.workspaces.first?.screens.first?.panes.first)
            let surface = try await connection.newTab(in: paneModel.handle).surface
            try await PinnedPageTests.until({ store.tab(surface: surface) != nil })
            let tab = try #require(store.tab(surface: surface))
            let pane = try #require(services.paneController(for: paneModel))
            try await PinnedPageTests.until({ pane.orderedIDs.map(\.rawValue).contains(tab.id) })
            pane.select(TabID(tab.id))
            try #require(services.windows.active?.focusedPane === pane, "the terminal's pane is not the focused one")
            // The shell sits at its prompt and says so (OSC 133 A); no command runs.
            try #require(tab.commandSinceMs == nil, "a command runs in the new terminal")
            try await Self.mark("A", on: tab, services)
            try await PinnedPageTests.until({ tab.promptSinceMs != nil && tab.commandSinceMs == nil }, within: .seconds(10),
                                            report: { "no prompt reached the store: prompt \(String(describing: tab.promptSinceMs)), command \(String(describing: tab.commandSinceMs))" })
            try #require(TabCloseGuard.asks([tab], services: services), "the terminal close warning does not apply")
            // The app read what the terminal runs while it had the focus, before the key (TerminalProcessReadAhead).
            try await PinnedPageTests.until({ services.terminalReadAhead.fresh([tab]) != nil }, within: .seconds(10),
                                            report: { "no answer read before the key for \(tab.surface) (\(tab.id)); focus \(String(describing: services.windows.active?.focus.state.resolved)), live \(tab.isLiveTerminal)" })
            let answer = try #require(services.terminalReadAhead.fresh([tab]))
            #expect(answer.keys.contains(tab.surface) && answer.programNames.isEmpty, "the idle shell read as running a program: \(answer)")
            try await body(services, store, pane, tab)
        }
    }
}
