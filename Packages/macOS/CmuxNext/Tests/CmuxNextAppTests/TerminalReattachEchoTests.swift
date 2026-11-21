import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// After every re-attach (a Cloud link that redialed, a relaunch) a terminal held its next resize
/// up to 30 frames (#25595): the replay's grid came while the attach was still pending and was
/// dropped, so the claim after the replay waited for an echo of a size the PTY already had. The
/// daemon announces no unchanged size, so that echo never came and `awaitsEcho` stayed set.
struct TerminalReattachEchoTests {
    typealias Machine = TerminalAttachMachine<Int>

    private func attempt(_ effects: [Machine.Effect]) -> Int? {
        for case .open(let attempt, _) in effects { return attempt }
        return nil
    }

    @Test func theReplaysGridCountsSoAClaimOfThatSizeWaitsForNoEcho() throws {
        let size = CellSize(cols: 120, rows: 40)
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: true)
        _ = machine.reduce(.resize(size))
        let open = try #require(attempt(machine.reduce(.start)))
        _ = machine.reduce(.opened(7, attempt: open))
        // The replay carries the PTY's grid, then the replay itself is delivered.
        _ = machine.reduce(.gridAnnounced(7, size))
        let effects = machine.reduce(.replayDelivered(7))
        #expect(effects.contains(.claim(7, size)))
        #expect(machine.announcedSize == size)
        #expect(machine.echoesDue.isEmpty, "a claim of the grid the PTY has waits for no echo: \(machine.echoesDue)")
    }

    @Test func aClaimOfAnotherSizeThanTheReplaysStillWaitsForItsEcho() throws {
        let size = CellSize(cols: 120, rows: 40)
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: true)
        _ = machine.reduce(.resize(size))
        let open = try #require(attempt(machine.reduce(.start)))
        _ = machine.reduce(.opened(7, attempt: open))
        // Another client holds the grid at 100x30: this view's claim changes it, so its echo is due.
        _ = machine.reduce(.gridAnnounced(7, CellSize(cols: 100, rows: 30)))
        _ = machine.reduce(.replayDelivered(7))
        #expect(machine.echoesDue == [size])
        _ = machine.reduce(.gridAnnounced(7, size))
        #expect(machine.echoesDue.isEmpty)
    }

    @Test func aGridOfAnAttachThatWasSupersededIsIgnored() throws {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: true)
        let open = try #require(attempt(machine.reduce(.start)))
        _ = machine.reduce(.opened(7, attempt: open))
        _ = machine.reduce(.gridAnnounced(9, CellSize(cols: 100, rows: 30)))
        #expect(machine.announcedSize == nil)
    }
}
