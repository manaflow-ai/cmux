@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextTerminal
import Foundation
import Testing

/// S2b slice 2: the daemon adapter maps snapshot steps to the surface's
/// in-place restore, and asks for snapshots at the linked libghostty's
/// GHOSTSNP version.
@Suite struct DaemonTerminalSnapshotEventTests {
    @Test func readyAndHistoryBecomeInPlaceRestores() {
        let ready = TerminalSnapshotFrame(phase: .ready, generation: 2, offset: 9, version: 1,
                                          cols: 80, rows: 24, data: Data("READY".utf8))
        #expect(DaemonTerminalIO.event(for: .snapshot(ready)) == .snapshot(Data("READY".utf8), phase: .ready))
        let history = TerminalSnapshotFrame(phase: .history, generation: 2, offset: 9, version: 1, data: Data("PAGES".utf8))
        #expect(DaemonTerminalIO.event(for: .snapshot(history)) == .snapshot(Data("PAGES".utf8), phase: .history))
    }

    /// S2c: a local-history READY becomes the local reflow restore, with the
    /// host's grid and history check.
    @Test func aLocalReadyBecomesTheLocalHistoryRestore() {
        let local = TerminalSnapshotFrame(phase: .ready, generation: 2, offset: 9, version: 1, cols: 25, rows: 10,
                                          localHistory: TerminalLocalHistoryCheck(rows: 7, digest: Data([9])),
                                          data: Data("READY".utf8))
        let expected = TerminalLocalHistory(columns: 25, rows: 10, historyRows: 7, digest: Data([9]))
        #expect(DaemonTerminalIO.event(for: .snapshot(local)) == .snapshot(Data("READY".utf8), phase: .readyLocalHistory(expected)))
        #expect(DaemonTerminalIO.attachLocalHistory == TerminalSession.restoresLocalHistory)
    }

    /// The version comes from the linked GhosttyNextKit; 0 would mean the
    /// library cannot restore snapshots, and the attach must then not ask.
    @Test func attachAsksAtTheLinkedSnapshotVersion() {
        #expect(TerminalSession.snapshotVersion != 0)
        #expect(DaemonTerminalIO.attachSnapshotVersion == TerminalSession.snapshotVersion)
    }
}
