import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// A restored terminal pane said "Restoring…" for up to a minute and came back only when the
/// person typed (#23029): its attaches had failed while the daemon was busy, it backed off like
/// any dropped link (500 ms doubling to 30 s), and a key press was the only thing that cut the
/// wait short. A connection that came back while an attach was in flight was dropped as well.
struct TerminalRestoreAttachTests {
    typealias Machine = TerminalAttachMachine<Int>

    /// The attempt the effects open, and the backoff step it waits first (0: at once).
    private func opened(_ effects: [Machine.Effect]) -> (attempt: Int, wait: Int)? {
        for effect in effects {
            switch effect {
            case .open(let attempt, _): return (attempt, 0)
            case .openAfterBackoff(let attempt, _, let failed): return (attempt, failed)
            default: continue
            }
        }
        return nil
    }

    @Test func aRestoredViewKeepsRetryingWithinTwoSecondsUntilItFirstAttaches() throws {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: true)
        var next = try #require(opened(machine.reduce(.start)))
        // About 90 s of failed attaches at the restore backoff: never more than step 3 (2 s)
        // between tries, and still "Restoring…" (no Retry yet), with no input.
        for failure in 1...40 {
            next = try #require(opened(machine.reduce(.openFailed(attempt: next.attempt))))
            #expect(next.wait <= 3, "failure \(failure) waits backoff step \(next.wait)")
            #expect(machine.status == .restoring, "failure \(failure): \(machine.status)")
        }
        // The daemon answers: the next attach goes live by itself.
        _ = machine.reduce(.opened(7, attempt: next.attempt))
        _ = machine.reduce(.replayDelivered(7))
        #expect(machine.status == .connected)
    }

    @Test func aRestoreThatNeverAttachesOffersRetryAndBacksOffAsBefore() throws {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: true)
        var next = try #require(opened(machine.reduce(.start)))
        for _ in 1...60 { next = try #require(opened(machine.reduce(.openFailed(attempt: next.attempt)))) }
        // A daemon that never answers is not asked every 2 s for good: Retry shows, and the
        // view still retries by itself at the longer backoff.
        #expect(machine.status == .disconnected(.attachFailed, reconnecting: false))
        #expect(next.wait > 3)
    }

    @Test func theConnectionBackDuringAnAttachReattachesAtOnceWhenThatAttachFails() throws {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: true)
        var next = try #require(opened(machine.reduce(.start)))
        for _ in 1...5 { next = try #require(opened(machine.reduce(.openFailed(attempt: next.attempt)))) }
        #expect(next.wait > 0)
        // That attach opened and waits for its replay when the daemon connection comes back.
        _ = machine.reduce(.opened(7, attempt: next.attempt))
        #expect(opened(machine.reduce(.reconnect)) == nil)
        // Its stream then ends (it was on the old connection): the next attach opens at once.
        let after = try #require(opened(machine.reduce(.ended(7, .connectionLost("gone")))))
        #expect(after.wait == 0)
        #expect(machine.status == .restoring)
    }
}
