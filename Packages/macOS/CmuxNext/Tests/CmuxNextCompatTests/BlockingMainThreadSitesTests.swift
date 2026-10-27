@testable import CmuxNextCompat
import Dispatch
import Testing

/// ``BlockingDetector/mainThreadSites``, what the opt-in hang reports count (p12-perf-process-226), and the
/// detector's fast path that makes those counts cheap in a nightly-next build: a known site's repeat only counts.
@Suite(.serialized)
struct BlockingMainThreadSitesTests {
    #if DEBUG || CMUX_BLOCKING_CHECKS
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
    #else
    /// Release has no detector: no site is ever listed, so a report carries none.
    @Test func withoutTheDetectorNoSiteIsListed() {
        #expect(BlockingDetector.forProcess().mainThreadSites.isEmpty)
    }
    #endif
}

#if DEBUG || CMUX_BLOCKING_CHECKS
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
