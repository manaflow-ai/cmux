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
    /// until it ends, so that "no program" would hold for a whole build. Once a command runs, Cmd-W reads at the key again
    /// and the tab stays until the daemon answers (the close question can show).
    @Test func cmdWAfterACommandStartedReadsAtTheKeyAgain() async throws {
        try await Self.withIdleFocusedTerminal { services, _, pane, tab in
            // The shell runs a command now (OSC 133 C: `extra.busy.since_ms`), and leaves its prompt.
            tab.promptSinceMs = nil
            tab.commandSinceMs = 1_762_000_001_000
            #expect(services.terminalReadAhead.fresh([tab]) == nil, "the prompt's answer stands for a running command")

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
            // The shell sits at its prompt. A person's zsh, bash or fish reports it (OSC 133, cmux-tui's shell integration)
            // and the store mirrors it (`extra.prompt.since_ms`); the harness's /bin/sh has no integration, so the test
            // puts that report in the store as a snapshot would. No command runs.
            try #require(tab.commandSinceMs == nil, "a command runs in the new terminal")
            tab.promptSinceMs = 1_762_000_000_000
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
