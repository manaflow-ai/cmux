import CmuxNextCompat
@testable import CmuxNextTrace
import Darwin
import Testing

/// The hang-watch slot table and its monitor rule (p09-observability 066 and 067's rule),
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
        #expect(first.first?.tier == .jank)
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
        // Scopes that opened and closed between two scans are a change (their closed mark): one more
        // period; a period with none goes back to the job's deadline.
        now.advance(.milliseconds(100))
        #expect(watch.scan(nowNanos: now.nanos).nextScanNanos == now.nanos + Self.nanos(.milliseconds(100)))
        now.advance(.milliseconds(100))
        #expect(watch.scan(nowNanos: now.nanos).nextScanNanos == now.start + Self.nanos(.seconds(30)))
        long.close()
        now.advance(.seconds(30))
        _ = watch.scan(nowNanos: now.nanos)
        now.advance(.milliseconds(100))
        #expect(watch.scan(nowNanos: now.nanos).nextScanNanos == nil, "nothing open: parked")
        #expect(wakes.count == 2)
    }

    /// Two tiers: a jank at the budget, then a hang `hangAfterBudget` (2 s) later,
    /// each once; the jank plans the scan of the hang, so a quiet monitor sleeps to it.
    @Test func aScopeJanksAtItsBudgetAndHangsTwoSecondsLater() {
        let (watch, now, _) = Self.monitored()
        let thread = watch.registerThread(.io, name: "test.tiers")
        let scope = watch.watch(thread, deadline: .milliseconds(100))
        now.advance(.milliseconds(150))
        let jank = watch.scan(nowNanos: now.nanos)
        #expect(jank.overdue.map(\.tier) == [.jank])
        #expect(jank.overdue.first?.deadlineNanos == now.start + Self.nanos(.milliseconds(100)))
        now.advance(.milliseconds(100))
        let quiet = watch.scan(nowNanos: now.nanos)
        #expect(quiet.overdue.isEmpty)
        #expect(quiet.nextScanNanos == now.start + Self.nanos(.milliseconds(2_100)), "sleeps to the hang tier")
        now.advance(.seconds(2))
        let hang = watch.scan(nowNanos: now.nanos).overdue
        #expect(hang.map(\.tier) == [.hang])
        #expect(hang.first?.deadlineNanos == now.start + Self.nanos(.milliseconds(100)), "both tiers name the budget")
        #expect(hang.first.map(watch.isStillOpen) == true)
        now.advance(.seconds(10))
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty, "each tier once")
        scope.close()
    }

    /// A scan that comes after both tiers' deadlines returns only the hang.
    @Test func aLateScanReportsOnlyTheHang() {
        let (watch, now, _) = Self.monitored()
        let thread = watch.registerThread(.io, name: "test.late")
        let scope = watch.watch(thread, deadline: .milliseconds(100))
        now.advance(.seconds(3))
        #expect(watch.scan(nowNanos: now.nanos).overdue.map(\.tier) == [.hang])
        now.advance(.seconds(3))
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty)
        scope.close()
    }

    /// An outer scope that janked keeps its jank under an inner scope: when the inner one closes, the
    /// outer one's hang tier is planned and reported, and its jank is not reported again.
    @Test func aJankedOuterScopeStillHangsAfterAnInnerOneCloses() {
        let (watch, now, wakes) = Self.monitored()
        let thread = watch.registerThread(.io, name: "test.outer-hang")
        let outer = watch.watch(thread, deadline: .milliseconds(100))
        now.advance(.milliseconds(150))
        #expect(watch.scan(nowNanos: now.nanos).overdue.map(\.tier) == [.jank])
        now.advance(.milliseconds(100))
        _ = watch.scan(nowNanos: now.nanos) // quiet: sleeps to the hang tier at 2.1 s
        let inner = watch.watch(thread, deadline: .seconds(10))
        let before = wakes.count
        inner.close()
        #expect(wakes.count == before, "the plan already covers the outer hang tier")
        #expect(watch.nextScanNanos == now.start + Self.nanos(.milliseconds(2_100)))
        now.advance(.seconds(2))
        let hang = watch.scan(nowNanos: now.nanos).overdue
        #expect(hang.map(\.tier) == [.hang])
        #expect(hang.map(\.name) == ["test.outer-hang"])
        outer.close()
    }

    /// A scan that lands inside an inner scope's open, after its clock read and before its deadline is in
    /// the slot, marks the outer scope as a jank. The inner scope keeps that mark, so when it closes the
    /// outer jank is not reported a second time, and the outer hang is still reported once.
    @Test func aJankMarkedDuringAnInnerOpenIsNotReportedAgain() {
        let (watch, hook) = Self.scannedOnClockRead()
        let now = hook.now
        let thread = watch.registerThread(.io, name: "test.mid-open-jank")
        let outer = watch.watch(thread, deadline: .milliseconds(100))
        now.advance(.milliseconds(150))
        hook.arm()
        let inner = watch.watch(thread, deadline: .seconds(10))
        #expect(hook.janks == 1, "the scan inside the open reports the outer jank")
        inner.close()
        now.advance(.milliseconds(100))
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty, "the outer jank was reported already")
        now.advance(.seconds(2))
        #expect(watch.scan(nowNanos: now.nanos).overdue.map(\.tier) == [.hang])
        now.advance(.seconds(1))
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty)
        outer.close()
    }

    /// The same for a hang: a scan inside an inner scope's open reports the outer scope as hung, and the
    /// outer scope is not reported again when the inner one closes.
    @Test func aHangMarkedDuringAnInnerOpenIsNotReportedAgain() {
        let (watch, hook) = Self.scannedOnClockRead()
        let now = hook.now
        let thread = watch.registerThread(.io, name: "test.mid-open-hang")
        let outer = watch.watch(thread, deadline: .milliseconds(100))
        now.advance(.milliseconds(2_200))
        hook.arm()
        let inner = watch.watch(thread, deadline: .seconds(10))
        #expect(hook.hangs == 1, "the scan inside the open reports the outer hang")
        inner.close()
        now.advance(.seconds(1))
        #expect(watch.scan(nowNanos: now.nanos).overdue.isEmpty, "the outer hang was reported already")
        outer.close()
    }

    /// A scope reported as a hang that ends moves the plan to now and wakes the parked monitor, which then
    /// takes its thread off the hung threads.
    @Test func closingAReportedScopeWakesTheParkedMonitor() {
        let (watch, now, wakes) = Self.monitored()
        let thread = watch.registerThread(.io, name: "test.reported-close")
        let scope = watch.watch(thread, deadline: .milliseconds(100))
        now.advance(.milliseconds(150))
        #expect(watch.scan(nowNanos: now.nanos).overdue.map(\.tier) == [.jank])
        now.advance(.milliseconds(100))
        _ = watch.scan(nowNanos: now.nanos) // quiet: sleeps to the hang tier
        now.advance(.seconds(2))
        let hang = watch.scan(nowNanos: now.nanos)
        #expect(hang.overdue.map(\.tier) == [.hang])
        #expect(hang.nextScanNanos == nil, "nothing else is due: parked")
        let before = wakes.count
        scope.close()
        #expect(wakes.count == before + 1)
        #expect(watch.nextScanNanos == now.nanos)
    }

    /// A reported scope that closes while the monitor's scan marks it: whichever lands first, a hang the
    /// scan reports is followed by a wake from the close (so its crash key is cleared), and nothing is
    /// reported after the close. The close runs on one thread and the scan on another, 20,000 rounds, the
    /// close moved by a few loads each round.
    @Test func aScopeThatClosesDuringTheHangScanStillWakesTheMonitor() {
        let (watch, now, wakes) = Self.monitored()
        let race = CloseRace()
        let rounds = 20_000
        runOnThreads(2) { tag in
            if tag == 1 {
                for round in 1...rounds {
                    while race.go.load(ordering: .acquiring) != round {}
                    let overdue = watch.scan(nowNanos: now.nanos).overdue
                    race.hung.store(overdue.contains { $0.tier == .hang }, ordering: .relaxed)
                    race.done.store(round, ordering: .releasing)
                }
                return
            }
            let thread = watch.registerThread(.io, name: "test.close-race")
            for round in 1...rounds {
                let scope = watch.watch(thread, deadline: .milliseconds(100))
                now.advance(.milliseconds(150))
                _ = watch.scan(nowNanos: now.nanos) // the jank
                now.advance(.milliseconds(100))
                _ = watch.scan(nowNanos: now.nanos) // quiet: sleeps to the hang tier
                now.advance(.seconds(2))
                let before = wakes.count
                race.go.store(round, ordering: .releasing) // the other thread scans now
                for _ in 0..<(round % 32) { _ = race.go.load(ordering: .relaxed) }
                scope.close()
                while race.done.load(ordering: .acquiring) != round {}
                if race.hung.load(ordering: .relaxed) {
                    race.hangs.add(1, ordering: .relaxed)
                    if wakes.count == before { race.missedWakes.add(1, ordering: .relaxed) }
                }
                if !watch.scan(nowNanos: now.nanos).overdue.isEmpty { race.reportedAfterClose.add(1, ordering: .relaxed) }
            }
        }
        #expect(race.hangs.load(ordering: .relaxed) > 0, "no round had the scan mark the scope before it closed")
        #expect(race.missedWakes.load(ordering: .relaxed) == 0)
        #expect(race.reportedAfterClose.load(ordering: .relaxed) == 0)
    }

    /// "No syscall on scope enter or exit in steady state": a lane busy for 20 scan
    /// periods (2,000 scopes, all closed before each scan) wakes the monitor once, at the first open
    /// after the park; the monitor keeps its period, and parks after the first quiet period.
    @Test func aBusyLaneMakesNoWakeCallInSteadyState() {
        let (watch, now, wakes) = Self.monitored()
        let lane = watch.registerLane("test.busy")
        watch.watch(lane, deadline: .milliseconds(100)) {}
        #expect(wakes.count == 1, "the first open after the park")
        for _ in 0..<20 {
            for _ in 0..<100 {
                now.advance(.milliseconds(1))
                watch.watch(lane, deadline: .milliseconds(100)) {}
            }
            #expect(watch.scan(nowNanos: now.nanos).nextScanNanos == now.nanos + Self.nanos(.milliseconds(100)))
        }
        #expect(wakes.count == 1, "\(wakes.count) wake calls for 2,001 scopes")
        now.advance(.milliseconds(100))
        #expect(watch.scan(nowNanos: now.nanos).nextScanNanos == nil, "a quiet period: parked")
        watch.watch(lane, deadline: .milliseconds(100)) {}
        #expect(wakes.count == 2, "the next open after the park wakes it again")
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

    /// A slot table whose clock runs one scan inside its next read, once armed.
    private static func scannedOnClockRead() -> (HangWatch, ScanOnClockRead) {
        let hook = ScanOnClockRead()
        let watch = HangWatch(clock: TraceClock(reader: .init(uptimeNanos: { hook.read() }, continuousNow: { ContinuousClock.now })))
        watch.attachMonitor {}
        hook.attach(watch)
        return (watch, hook)
    }

    private static func nanos(_ duration: Duration) -> UInt64 { HangWatch.nanos(duration) }
}

/// Runs one monitor scan inside the slot table's next clock read once armed: the read that
/// `watch(_:deadline:)` makes while it opens a scope, so the scan lands in the middle of the open.
private final class ScanOnClockRead: Sendable {
    let now = ManualNow()
    /// The slot table, unretained (the test holds it).
    private let table = Atomic<UInt>(0)
    private let armed = Atomic<Bool>(false)
    private let jankCount = Atomic<Int>(0)
    private let hangCount = Atomic<Int>(0)

    var janks: Int { jankCount.load(ordering: .acquiring) }
    var hangs: Int { hangCount.load(ordering: .acquiring) }

    func attach(_ watch: HangWatch) {
        table.store(UInt(bitPattern: Unmanaged.passUnretained(watch).toOpaque()), ordering: .releasing)
    }

    func arm() { armed.store(true, ordering: .releasing) }

    func read() -> UInt64 {
        if armed.exchange(false, ordering: .acquiringAndReleasing),
           let pointer = UnsafeRawPointer(bitPattern: table.load(ordering: .acquiring)) {
            let overdue = Unmanaged<HangWatch>.fromOpaque(pointer).takeUnretainedValue().scan(nowNanos: now.nanos).overdue
            jankCount.add(overdue.filter { $0.tier == .jank }.count, ordering: .acquiringAndReleasing)
            hangCount.add(overdue.filter { $0.tier == .hang }.count, ordering: .acquiringAndReleasing)
        }
        return now.nanos
    }
}

/// A close racing a scan on two threads: each round's hand-offs, and what the rounds saw.
private final class CloseRace: Sendable {
    let go = Atomic<Int>(0)
    let done = Atomic<Int>(0)
    let hung = Atomic<Bool>(false)
    let hangs = Atomic<Int>(0)
    let missedWakes = Atomic<Int>(0)
    let reportedAfterClose = Atomic<Int>(0)
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
