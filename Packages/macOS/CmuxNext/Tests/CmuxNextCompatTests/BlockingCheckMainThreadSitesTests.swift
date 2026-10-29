#if DEBUG || CMUX_BLOCKING_CHECKS
@testable import CmuxNextCompat
import Dispatch
import Testing

/// ``BlockingDetector/mainThreadSites`` and ``BlockingDetector/mainThreadRead``, what the opt-in hang reports count,
/// and the detector's fast path that makes those counts cheap in a nightly-next build: a
/// known site's repeat only counts. The `BlockingCheck` prefix puts it in the nightly-configuration run of
/// `scripts/measure/blocking-checks.sh` as well as the Debug one.
@Suite(.serialized)
struct BlockingCheckMainThreadSitesTests {
    /// A main-thread site is listed; a pool site is a site of its own context, and not a main-thread wait.
    @MainActor @Test func mainThreadSitesListOnlyTheMainThreadsSites() async {
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) { blockingCall(.fileIO) {} }
        await BlockingViolationTable.$scoped.withValue(table) { await blockingCallOnTheGlobalQueue() }
        await table.flush()

        let detector = BlockingDetector(table: table)
        #expect(Set(detector.sites.map(\.context)) == [.main, .pool])
        #expect(detector.mainThreadSites.map(\.kind) == [.fileIO])
        #expect(detector.mainThreadSites.map(\.context) == [.main])
        #expect(detector.mainThreadRead == BlockingDetector.MainThreadRead(resets: 0, sites: detector.mainThreadSites))
    }

    /// The stack is captured once, when a site is new, and goes to the drain in one ring slot; a repeat only adds
    /// to the site's counters. With the drain held, 200 calls at one site fit the 64-slot ring with no overflow (a
    /// capture and push per call would overflow it) and count 200.
    @MainActor @Test func aRepeatOfAKnownSiteOnlyCounts() async {
        let table = BlockingViolationTable(mode: .record, startsDrain: false)
        BlockingViolationTable.$scoped.withValue(table) {
            for _ in 0 ..< 200 { blockingCall(.fileIO) {} }
        }
        #expect(table.overflow(in: .main) == 0)
        table.startDrain()
        await table.flush()

        #expect(BlockingDetector(table: table).mainThreadSites.map(\.count) == [200])
    }

    /// A reset zeroes the counts and adds one to the read's reset count, so a reader that keeps a baseline (the hang
    /// reports' ledger) knows every later call is new.
    @MainActor @Test func aResetZeroesTheCountsAndIsCountedInTheRead() async {
        let table = BlockingViolationTable(mode: .record)
        BlockingViolationTable.$scoped.withValue(table) {
            for _ in 0 ..< 3 { blockingCall(.fileIO) {} }
        }
        await table.flush()
        let detector = BlockingDetector(table: table)
        #expect(detector.mainThreadRead.resets == 0)
        #expect(detector.mainThreadRead.sites.map(\.count) == [3])

        detector.resetCounts()
        #expect(detector.mainThreadRead.resets == 1)
        #expect(detector.mainThreadRead.sites.map(\.count) == [0])
    }
}

/// One `blockingCall(.sqlite)` on a GCD root queue (a pool thread), reported to the caller's scoped table: a dispatch
/// block does not inherit task-locals, so the table is bound again on that thread.
private nonisolated func blockingCallOnTheGlobalQueue() async {
    let table = BlockingViolationTable.scoped
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global(qos: .utility).async {
            BlockingViolationTable.$scoped.withValue(table) { blockingCall(.sqlite) {} }
            done.resume()
        }
    }
}
#endif
