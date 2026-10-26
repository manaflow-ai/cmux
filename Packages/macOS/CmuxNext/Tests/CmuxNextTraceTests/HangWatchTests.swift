import CmuxNextCompat
@testable import CmuxNextTrace
import Darwin
import Testing

/// The hang-watch slot table and its monitor rule (p02-threads-016, p09-observability 066 and 067's rule),
/// on a clock that moves only when the test moves it: Chrome's `base::HangWatcher`
/// (base/threading/hang_watcher.cc) with a monitor that parks while nothing opens.
@Suite("Hang watch slots") struct HangWatchTests {
    /// 2,000 lanes each get their own slot; a freed slot comes back with the next generation.
    @Test func twoThousandRegistrationsGetTheirOwnSlots() {
        let watch = HangWatch()
        let lanes = (0..<2_000).map { _ in watch.registerLane("test.lane") }
        #expect(Set(lanes.map(\.slot)).count == 2_000)
        #expect(lanes.allSatisfy { $0.generation == 1 })
        #expect(watch.registrationOverflows == 0)
        watch.unregister(lanes[0])
        let again = watch.registerLane("test.again")
        #expect(again.slot == lanes[0].slot)
        #expect(again.generation == 2)
    }

    @Test func aRegistrationPastTheTableIsCountedAndWatchesNothing() {
        let watch = HangWatch()
        for _ in 0..<HangWatch.capacity { _ = watch.registerLane("test.full") }
        let refused = watch.registerLane("test.refused")
        #expect(refused.generation == 0)
        #expect(watch.registrationOverflows == 1)
        #expect(watch.watch(refused, deadline: .milliseconds(1)) { 3 } == 3)
    }

    /// A scope past its deadline is returned once, however many scans see it.
    @Test func anOverdueScopeIsReportedOnce() {
        let (watch, now, _) = Self.monitored()
        let thread = watch.registerThread(.io, name: "test.io")
        let scope = watch.watch(thread, deadline: .milliseconds(100))
        now.advance(.milliseconds(50))
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty)
        now.advance(.milliseconds(100))
        let first = watch.scan(nowNanos: now.nanos).overdue
        #expect(first.map(\.name) == ["test.io"])
        #expect(first.first?.kind == .io)
        #expect(first.first?.port == UInt32(truncatingIfNeeded: HangWatch.currentPort()))
        #expect(first.first.map(watch.isStillOpen) == true)
        now.advance(.seconds(1))
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty)
        scope.close()
        #expect(first.first.map(watch.isStillOpen) == false)
    }

    /// An outer scope reported, then an inner one reported: when the inner one closes, the outer one
    /// comes back with its reported flag and is not reported a second time.
    @Test func aReportedOuterScopeIsNotReportedAgainAfterAnInnerOneCloses() {
        let (watch, now, _) = Self.monitored()
        let thread = watch.registerThread(.io, name: "test.nested")
        let outer = watch.watch(thread, deadline: .milliseconds(100))
        now.advance(.milliseconds(150))
        #expect(watch.scan(nowNanos: now.nanos).overdue.count == 1)
        let inner = watch.watch(thread, deadline: .milliseconds(100))
        now.advance(.milliseconds(150))
        #expect(watch.scan(nowNanos: now.nanos).overdue.count == 1)
        inner.close()
        now.advance(.seconds(1))
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty)
        outer.close()
    }

    /// An outer scope past its deadline under a long inner one: closing the inner one wakes the monitor,
    /// which sleeps to the inner deadline, and the next scan reports the outer one.
    @Test func closingAnInnerScopeRestoresAnOverdueOuterOne() {
        let (watch, now, wakes) = Self.monitored()
        let thread = watch.registerThread(.io, name: "test.outer")
        let outer = watch.watch(thread, deadline: .milliseconds(100))
        let inner = watch.watch(thread, deadline: .seconds(10))
        now.advance(.milliseconds(50))
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty) // a change: one more period
        now.advance(.milliseconds(100))
        let quiet = watch.scan(nowNanos: now.nanos)
        #expect(quiet.overdue.isEmpty, "the inner deadline is 10 s away")
        #expect(quiet.nextScanNanos == now.start + Self.nanos(.seconds(10)), "no change: sleep to the earliest deadline")
        let before = wakes.count
        inner.close()
        #expect(wakes.count == before + 1)
        #expect(watch.nextScanNanos == now.start + Self.nanos(.milliseconds(100)))
        #expect(watch.scan(nowNanos: now.nanos).overdue.map(\.name) == ["test.outer"])
        outer.close()
    }

    /// The monitor rule: parked, the first open wakes it; opens within a period of its plan do not; with
    /// no change it sleeps to the earliest deadline, so one long scope costs no periodic wake; a short
    /// scope under that long plan wakes it once.
    @Test func theMonitorWakesOnlyWhenItsPlanWouldBeLate() {
        let (watch, now, wakes) = Self.monitored()
        let job = watch.registerLane("test.job")
        let feed = watch.registerLane("test.feed")
        #expect(watch.nextScanNanos == nil, "parked")
        let long = watch.watch(job, deadline: .seconds(30))
        #expect(wakes.count == 1)
        #expect(watch.nextScanNanos == now.start + Self.nanos(.seconds(30)), "no periodic cap: the job's deadline")
        now.advance(.seconds(1))
        let opened = now.nanos
        watch.watch(feed, deadline: .milliseconds(100)) {}
        #expect(wakes.count == 2, "the plan was 29 s late for this scope")
        #expect(watch.nextScanNanos == opened + Self.nanos(.milliseconds(100)))
        // The scan finds a change: one more scan a period later, and opens before it wake nobody.
        now.advance(.milliseconds(100))
        #expect(watch.scan(nowNanos: now.nanos).nextScanNanos == now.nanos + Self.nanos(.milliseconds(100)))
        for _ in 0..<50 { watch.watch(feed, deadline: .milliseconds(100)) {} }
        #expect(wakes.count == 2)
        // Scopes that opened and closed between two scans leave no change: back to the job's deadline.
        now.advance(.milliseconds(100))
        #expect(watch.scan(nowNanos: now.nanos).nextScanNanos == now.start + Self.nanos(.seconds(30)))
        long.close()
        now.advance(.seconds(30))
        _ = watch.scan(nowNanos: now.nanos)
        now.advance(.milliseconds(100))
        #expect(watch.scan(nowNanos: now.nanos).nextScanNanos == nil, "nothing open: parked")
        #expect(wakes.count == 2)
    }

    /// `invalidateActive()` cancels the open scopes of the calling thread; the next one watches again,
    /// and when it closes the cancelled one around it stays cancelled.
    @Test func invalidatedScopesAreNotReported() {
        let (watch, now, _) = Self.monitored()
        let thread = watch.registerThread(.io, name: "test.wait")
        let outer = watch.watch(thread, deadline: .milliseconds(100))
        watch.invalidateActive()
        now.advance(.milliseconds(200))
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty)
        let inner = watch.watch(thread, deadline: .milliseconds(100))
        now.advance(.milliseconds(200))
        #expect(watch.scan(nowNanos: now.nanos).overdue.count == 1)
        inner.close()
        now.advance(.milliseconds(200))
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty)
        outer.close()
    }

    /// A scope of a freed registration does not touch the slot's next owner.
    @Test func aStaleScopeLeavesTheNextOwnerAlone() {
        let (watch, now, _) = Self.monitored()
        let old = watch.registerLane("test.old")
        let stale = watch.watch(old, deadline: .seconds(10))
        watch.unregister(old)
        let next = watch.registerLane("test.next")
        #expect(next.slot == old.slot)
        let scope = watch.watch(next, deadline: .milliseconds(100))
        stale.close()
        now.advance(.milliseconds(200))
        #expect(watch.scan(nowNanos: now.nanos).overdue.map(\.name) == ["test.next"])
        scope.close()
        #expect(watch.watch(old, deadline: .milliseconds(1)) { 5 } == 5)
    }

    @Test func aDetachedMonitorIsNeverWoken() {
        let (watch, now, wakes) = Self.monitored()
        watch.detachMonitor()
        let lane = watch.registerLane("test.detached")
        let scope = watch.watch(lane, deadline: .milliseconds(100))
        now.advance(.seconds(1))
        #expect(wakes.count == 0)
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty)
        #expect(watch.nextScanNanos == nil)
        scope.close()
        #expect(watch.attachMonitor(wake: {}) == false, "one monitor per table")
    }

    /// Opening and closing a scope is a clock read and a few atomic stores and loads: under 50 ns at p99
    /// (per pair, over batches of 256), with one monitor wake in the whole run (the first open after the
    /// park). Optimized builds only, as the trace ring's cost tests; elsewhere it shows as skipped.
    @Test(.enabled(if: !_isDebugAssertConfiguration(), "needs an optimized build (-c release)"))
    func openAndCloseCostUnderFiftyNanoseconds() {
        let watch = HangWatch()
        let wakes = WakeCount()
        watch.attachMonitor { wakes.add() }
        let lane = watch.registerLane("test.cost")
        let batches = 2_000
        let pairs = 256
        var perPair: [Double] = []
        perPair.reserveCapacity(batches)
        for _ in 0..<batches {
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            for _ in 0..<pairs { watch.watch(lane, deadline: .milliseconds(100)).close() }
            perPair.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / Double(pairs))
        }
        perPair.sort()
        let p99 = perPair[batches * 99 / 100]
        print("hang watch open+close p99: \(p99) ns")
        #expect(p99 < 50, "\(p99) ns per open+close at p99")
        #expect(wakes.count == 1, "\(wakes.count) monitor wakes")
    }

    // MARK: - Support

    private static func monitored() -> (HangWatch, ManualNow, WakeCount) {
        let now = ManualNow()
        let wakes = WakeCount()
        let watch = HangWatch(clock: TraceClock(reader: .init(uptimeNanos: { now.nanos }, continuousNow: { ContinuousClock.now })))
        watch.attachMonitor { wakes.add() }
        return (watch, now, wakes)
    }

    private static func nanos(_ duration: Duration) -> UInt64 { HangWatch.nanos(duration) }
}

/// A `CLOCK_UPTIME_RAW` reading that moves only when the test moves it.
private final class ManualNow: Sendable {
    let start: UInt64 = 1_000_000_000_000
    private let offset = Atomic<UInt64>(0)

    var nanos: UInt64 { start + offset.load(ordering: .acquiring) }

    func advance(_ duration: Duration) {
        offset.add(HangWatch.nanos(duration), ordering: .acquiringAndReleasing)
    }
}

/// The monitor wakes a test's slot table asked for.
private final class WakeCount: Sendable {
    private let value = Atomic<Int>(0)
    var count: Int { value.load(ordering: .acquiring) }
    func add() { value.add(1, ordering: .acquiringAndReleasing) }
}
