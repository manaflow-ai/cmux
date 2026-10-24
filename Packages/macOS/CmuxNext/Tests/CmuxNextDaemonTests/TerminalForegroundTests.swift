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

    /// An older change (an event held across the seed) changes nothing; a seed replaces every
    /// entry, so state from before a daemon restart (whose surfaces keep their ids and start their
    /// sequence again) never wins over the new daemon's.
    @Test func theSeedReplacesEverythingAndNewerEventsApplyOnTop() {
        var foregrounds = TerminalForegrounds()
        _ = foregrounds.apply(TerminalForeground(surface: 1, seq: 50, foregroundPID: 9, foregroundExecutable: "make"))
        foregrounds.seed([TerminalForeground(surface: 1, seq: 2, foregroundExecutable: "zsh", command: "zsh"),
                          TerminalForeground(surface: 2, seq: 1, foregroundExecutable: "top")], epoch: 3)
        #expect(foregrounds.programs(of: [1, 2], epoch: 3) == [1: String?.none, 2: "top"])
        let older = foregrounds.apply(TerminalForeground(surface: 2, seq: 1, foregroundExecutable: "zsh", command: "zsh"))
        let newer = foregrounds.apply(TerminalForeground(surface: 1, seq: 3, foregroundPID: 11, foregroundExecutable: "vim"))
        #expect(!older)
        #expect(newer)
        #expect(foregrounds.programs(of: [1, 2], epoch: 3) == [1: "vim", 2: "top"] as [SurfaceID: String?])
    }

    /// Unknown is never "no program": before this connection's seed, after the connection changed,
    /// or for a surface with no entry, the answer is nil (the close asks the daemon).
    @Test func whatIsNotKnownForThisConnectionIsNil() {
        var foregrounds = TerminalForegrounds()
        _ = foregrounds.apply(TerminalForeground(surface: 1, seq: 1, foregroundExecutable: "vim"))
        #expect(foregrounds.programs(of: [1], epoch: 1) == nil, "events before the seed are not a seed")
        foregrounds.seed([TerminalForeground(surface: 1, seq: 1, foregroundExecutable: "vim")], epoch: 1)
        #expect(foregrounds.programs(of: [1], epoch: 1) == [1: "vim"] as [SurfaceID: String?])
        #expect(foregrounds.programs(of: [1, 2], epoch: 1) == nil, "a surface with no entry")
        #expect(foregrounds.programs(of: [1], epoch: 2) == nil, "another connection")
        foregrounds.reset()
        #expect(foregrounds.programs(of: [1], epoch: 1) == nil)
        #expect(foregrounds.bySurface.isEmpty)
    }

    /// The store applies each event; a connection change forgets everything; a closed tab's
    /// surface is forgotten.
    @Test func theStoreKeepsWhatTheDaemonPushedForThisConnection() {
        let store = DaemonStore()
        _ = store.apply(.terminalForegroundChanged(TerminalForeground(surface: 1, seq: 1, foregroundPID: 7, foregroundExecutable: "/usr/bin/top")))
        store.foregrounds.seed([TerminalForeground(surface: 1, seq: 1, foregroundPID: 7, foregroundExecutable: "/usr/bin/top")], epoch: store.connectionEpoch)
        #expect(store.foregrounds.programs(of: [1], epoch: store.connectionEpoch) == [1: "top"] as [SurfaceID: String?])
        _ = store.apply(.disconnected(reason: "socket closed"))
        #expect(store.foregrounds.programs(of: [1], epoch: store.connectionEpoch) == nil)
        #expect(store.foregrounds.bySurface.isEmpty)
    }

    /// A shell loop's changes coalesce like agent state: one value per surface per batch.
    @Test func foregroundChangesCoalescePerSurface() {
        let event = DaemonEvent.terminalForegroundChanged(TerminalForeground(surface: 4, seq: 1))
        #expect(CoalesceKey(event) == .foreground(4))
    }
}
