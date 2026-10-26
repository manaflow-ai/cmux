@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextWakeups
import Observation
import Testing

/// The CmuxNextApp root files T* to W* sweep (plans/cmux-next/chrome-parity/p06-scheduler.md, task p06-scheduler-303):
/// a wait for a tab ends on the change that brings it, through one keyed waiter and one posted task, never a poll or
/// a Task per change.
@MainActor @Suite(.timeLimit(.minutes(1))) struct RootFilesSchedulerSweepTests {
    @Test func aTabAlreadyInTheTreeEndsTheWaitWithNoObservation() async {
        let lookup = TabLookup(), work = linklessMainWork()
        lookup.found = true
        #expect(await TabMirror.reaches("t1", in: { lookup.locate($0) }, on: work))
        #expect(lookup.reads == 1, "a satisfied wait read the tree \(lookup.reads) times")
    }

    @Test func aTabMirrorWaitEndsInThePostedTaskAfterTheTreeHasTheTab() async {
        let lookup = TabLookup(), work = linklessMainWork()
        let waiter = Task { await TabMirror.reaches("t1", in: { lookup.locate($0) }, on: work) }
        // Filed: the first check, the observation's first read and the waiter's own first read.
        while lookup.reads < 3 { await Task.yield() }
        let filed = lookup.reads
        for _ in 0..<5 { lookup.unrelated += 1 }
        #expect(lookup.reads == filed, "a change the lookup does not read made it read again")

        lookup.found = true
        #expect(work.postedCount(.visible) == 1, "the change posted no flush")
        #expect(runMainLoop { work.postedCount(.visible) == 0 }, "the posted flush never ran")
        #expect(await waiter.value, "the wait did not end when the tree got the tab")
        // The re-armed tracking, the flush and the waiter's settle.
        #expect(lookup.reads - filed <= 3, "one change, \(lookup.reads - filed) reads")
    }
}

/// A tree lookup whose answer the test flips; it counts its reads.
@MainActor @Observable
private final class TabLookup {
    var found = false
    var unrelated = 0
    @ObservationIgnored private(set) var reads = 0
    @ObservationIgnored private let daemon = DaemonService()

    func locate(_ key: String) -> (pane: PaneID, daemon: DaemonService)? {
        reads += 1
        return found ? (PaneID(rawValue: 1), daemon) : nil
    }
}
