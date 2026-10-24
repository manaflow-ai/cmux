import Foundation
import Testing
@testable import CmuxNextDaemon

/// Each terminal's foreground program, pushed by the daemon (`terminal-foreground-v1`): the store
/// keeps the newest per surface, so a close decides its question in the key's turn.
@MainActor
struct TerminalForegroundTests {
    /// The wire event decodes, and the shell rule matches `process-info`'s.
    @Test func theEventDecodesAndAShellIsNoProgram() throws {
        let vim = #"{"event":"terminal-foreground-changed","surface":3,"seq":7,"foreground_pid":412,"foreground_executable":"/usr/bin/vim","command":null}"#
        guard case .terminalForegroundChanged(let foreground) = DaemonEvent.decode(name: "terminal-foreground-changed", line: Data(vim.utf8)) else {
            Issue.record("not decoded as terminal-foreground-changed")
            return
        }
        #expect(foreground == TerminalForeground(surface: 3, seq: 7, foregroundPID: 412, foregroundExecutable: "/usr/bin/vim"))
        #expect(foreground.runningProgram == "vim")
        #expect(TerminalForeground(surface: 3, seq: 8, foregroundPID: 400, foregroundExecutable: "-zsh").runningProgram == nil)
        #expect(DaemonEvent.terminalForegroundChanged(foreground).outlivesSnapshot)
    }

    /// An older change (an event held across a resync, after the seed) changes nothing; a seed
    /// keeps a held state that is newer than the listed one.
    @Test func theNewestChangePerSurfaceWins() {
        var foregrounds = TerminalForegrounds()
        let newer = foregrounds.apply(TerminalForeground(surface: 1, seq: 5, foregroundPID: 9, foregroundExecutable: "make"))
        let older = foregrounds.apply(TerminalForeground(surface: 1, seq: 4, foregroundPID: 8, foregroundExecutable: "zsh"))
        #expect(newer)
        #expect(!older)
        #expect(foregrounds.runningProgram(1) == "make")
        foregrounds.seed([TerminalForeground(surface: 1, seq: 3, foregroundExecutable: "zsh"),
                          TerminalForeground(surface: 2, seq: 1, foregroundExecutable: "top")])
        #expect(foregrounds.runningProgram(1) == "make")
        #expect(foregrounds.runningProgram(2) == "top")
        #expect(foregrounds.runningProgram(3) == nil)
    }

    /// The store applies the event as it arrives.
    @Test func theStoreKeepsWhatTheDaemonPushed() {
        let store = DaemonStore()
        _ = store.apply(.terminalForegroundChanged(TerminalForeground(surface: 1, seq: 1, foregroundPID: 7, foregroundExecutable: "/usr/bin/top")))
        #expect(store.foregrounds.runningProgram(1) == "top")
        _ = store.apply(.terminalForegroundChanged(TerminalForeground(surface: 1, seq: 2, foregroundPID: 6, foregroundExecutable: "zsh", command: "zsh")))
        #expect(store.foregrounds.runningProgram(1) == nil)
    }
}
