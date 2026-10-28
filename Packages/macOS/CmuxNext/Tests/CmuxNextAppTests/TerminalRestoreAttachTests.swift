import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextInputModel
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
        // between tries, with no input (the 5 s deadline that says why is the driver's, not here).
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

    /// The restore deadline the effects ask for, if any.
    private func stallArm(_ effects: [Machine.Effect]) -> Int? {
        effects.lazy.compactMap { if case .armRestoreStall(let arm) = $0 { arm } else { nil } }.first
    }

    /// Audit P13 (2026-10-28): "Restoring…" stayed up to about 90 s with no reason and no Retry
    /// (quietRestoreReconnects 45), and an attach that hung said nothing at all. A restored view
    /// still not live 5 s after its start says why and offers Retry, whatever its attach is doing,
    /// and keeps retrying at the short restore backoff by itself.
    @Test func aRestoreStillMissingAfterFiveSecondsSaysWhyAndOffersRetry() throws {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: true)
        let started = machine.reduce(.start)
        let arm = try #require(stallArm(started), "a restore asks for no deadline: it can say Restoring… for good")
        #expect(Machine.restoreStallDelay == .seconds(5))
        var next = try #require(opened(started))
        for _ in 1...3 { next = try #require(opened(machine.reduce(.openFailed(attempt: next.attempt)))) }
        #expect(machine.status == .restoring)
        _ = machine.reduce(.restoreStallDue(arm))
        #expect(machine.status == .disconnected(.restoreStalled, reconnecting: false),
                "5 s on, the view says \(machine.status), not why with Retry")
        // It keeps saying why while it retries by itself at the short backoff.
        for _ in 1...10 {
            next = try #require(opened(machine.reduce(.openFailed(attempt: next.attempt))))
            #expect(next.wait <= 3)
            #expect(machine.status == .disconnected(.restoreStalled, reconnecting: false))
        }
        // A late answer goes live with no input.
        _ = machine.reduce(.opened(7, attempt: next.attempt))
        _ = machine.reduce(.replayDelivered(7))
        #expect(machine.status == .connected)
        #expect(machine.reduce(.restoreStallDue(arm)).isEmpty, "a deadline after live changes nothing")
    }

    /// An attach that hangs (no failure, no replay) says why after 5 s too, and Retry visibly restarts:
    /// "Restoring…" again at once and a new deadline; the old deadline is stale.
    @Test func aHangingRestoreSaysWhyAndRetryShowsRestoringAgainAtOnce() throws {
        var machine = Machine(initialSize: CellSize(cols: 80, rows: 24), visible: true, restoring: true)
        let started = machine.reduce(.start)
        let first = try #require(stallArm(started))
        let open = try #require(opened(started))
        _ = machine.reduce(.opened(7, attempt: open.attempt))  // linked, its replay never comes
        _ = machine.reduce(.restoreStallDue(first))
        #expect(machine.status == .disconnected(.restoreStalled, reconnecting: false))
        let retried = machine.reduce(.reconnect)  // Retry, a key or a click
        #expect(machine.status == .restoring, "Retry left \(machine.status)")
        let second = try #require(stallArm(retried), "Retry asked for no new deadline")
        #expect(second != first)
        #expect(machine.reduce(.restoreStallDue(first)).isEmpty, "the stale deadline said why again")
        _ = machine.reduce(.restoreStallDue(second))
        #expect(machine.status == .disconnected(.restoreStalled, reconnecting: false))
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
