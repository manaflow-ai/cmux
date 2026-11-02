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
            // The shell sits at its prompt: the daemon reports OSC 133's prompt and no running command.
            try await PinnedPageTests.until({ tab.promptSinceMs != nil && tab.commandSinceMs == nil }, within: .seconds(30),
                                            report: { "prompt \(String(describing: tab.promptSinceMs)), command \(String(describing: tab.commandSinceMs))" })
            try #require(TabCloseGuard.asks([tab], services: services), "the terminal close warning does not apply")
            // Time for a read of the terminal made before the key, if the app makes one (its read is bounded at 1 s).
            try await Task.sleep(for: .milliseconds(1_500))

            let performed = services.registry.perform("closeTab", invocation: ActionInvocation(origin: .user))
            #expect(performed)
            #expect(!TabCloseGuard.reading.contains(tab.id), "Cmd-W waited for the daemon's read of the terminal")
            #expect(!pane.orderedIDs.map(\.rawValue).contains(tab.id), "the tab did not leave the strip in the key's turn")
            try await PinnedPageTests.until({ store.tab(surface: surface) == nil },
                                            report: { "waiting for the daemon close: reading \(TabCloseGuard.reading), asking \(TabCloseGuard.asking)" })
        }
    }
}
