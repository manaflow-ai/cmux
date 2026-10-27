#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
@testable import CmuxNextTrace
import Testing

/// `debug.hang_inject`'s slot-table side (p09-observability-088): an armed lane's next scope stays busy inside
/// the scope, once, so the monitor reports it as that lane's hang; unknown lanes, a second arm and a bad time are
/// refused. The clock steps 1 ms per read, so the busy loop ends without real time passing.
@Suite("Hang watch injection") struct HangWatchInjectTests {
    @Test func anArmedLaneIsBusyInsideItsNextScopeOnceAndReportedAsItsHang() throws {
        let (watch, clock) = Self.stepping()
        let lane = watch.registerLane("test.inject")
        let other = watch.registerLane("test.other")
        try watch.armHang(lane: "test.inject", busyFor: .seconds(3))
        #expect(watch.armedHang == "test.inject")

        watch.watch(other, deadline: .milliseconds(100)) {}
        #expect(watch.armedHang == "test.inject", "another lane's scope leaves the arm")

        let opened = clock.nanos
        let overdue = watch.watch(lane, deadline: .milliseconds(100)) {
            watch.scan(nowNanos: clock.nanos).overdue
        }
        #expect(clock.nanos - opened >= HangWatch.nanos(.seconds(3)), "the scope stayed busy for the armed time")
        #expect(overdue.map(\.name) == ["test.inject"])
        #expect(overdue.first?.tier == .hang)
        #expect(watch.armedHang == nil, "the arm was taken")

        let again = clock.nanos
        watch.watch(lane, deadline: .milliseconds(100)) {}
        #expect(clock.nanos - again < HangWatch.nanos(.milliseconds(10)), "taken once")
    }

    @Test func unknownLanesASecondArmAndBadTimesAreRefused() throws {
        let (watch, _) = Self.stepping()
        _ = watch.registerLane("test.a")
        _ = watch.registerLane("test.b")
        #expect(watch.registeredNames == ["test.a", "test.b"])
        #expect(throws: HangWatch.HangInjectError.unknownLane("test.c")) { try watch.armHang(lane: "test.c", busyFor: .seconds(1)) }
        #expect(throws: HangWatch.HangInjectError.badDuration) { try watch.armHang(lane: "test.a", busyFor: .zero) }
        #expect(throws: HangWatch.HangInjectError.badDuration) { try watch.armHang(lane: "test.a", busyFor: .seconds(31)) }
        try watch.armHang(lane: "test.a", busyFor: .seconds(1))
        #expect(throws: HangWatch.HangInjectError.alreadyArmed("test.a")) { try watch.armHang(lane: "test.b", busyFor: .seconds(1)) }
        #expect(watch.disarmHang() == "test.a")
        #expect(watch.disarmHang() == nil)
        try watch.armHang(lane: "test.b", busyFor: .seconds(1))
    }

    @Test func anUnregisteredLaneIsNoLongerListed() {
        let (watch, _) = Self.stepping()
        let lane = watch.registerLane("test.gone")
        watch.unregister(lane)
        #expect(watch.registeredNames.isEmpty)
        #expect(throws: HangWatch.HangInjectError.unknownLane("test.gone")) { try watch.armHang(lane: "test.gone", busyFor: .seconds(1)) }
    }

    private static func stepping() -> (HangWatch, SteppingClock) {
        let clock = SteppingClock()
        let watch = HangWatch(clock: TraceClock(reader: .init(uptimeNanos: { clock.read() }, continuousNow: { ContinuousClock.now })))
        watch.attachMonitor {}
        return (watch, clock)
    }
}

/// A clock that moves 1 ms forward at each read.
private final class SteppingClock: Sendable {
    private let now = Atomic<UInt64>(1_000_000_000)

    /// Now, without stepping.
    var nanos: UInt64 { now.load(ordering: .relaxed) }

    func read() -> UInt64 {
        now.add(1_000_000, ordering: .relaxed).newValue
    }
}
#endif
