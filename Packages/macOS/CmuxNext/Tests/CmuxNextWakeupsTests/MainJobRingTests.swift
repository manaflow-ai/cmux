#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import CmuxNextWakeups
import Testing

/// The main-job census's ring (p08-startup-080): bounded, the enqueuer's stack and priority per job, timed runs, and
/// nothing recorded once frozen. A test ring is never installed as the runtime's hook.
struct MainJobRingTests {
    /// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
    final class Ticks: Sendable {
        let value = Atomic<UInt64>(0)
        func set(_ nanos: UInt64) { value.store(nanos, ordering: .relaxed) }
        func read() -> UInt64 { value.load(ordering: .relaxed) }
    }

    @Test func keepsTheFirstJobsAndCountsTheRestAsDropped() {
        let ring = MainJobRing(capacity: 2)
        #expect(ring.recordEnqueue(.mainActor, priority: 25) == 0)
        #expect(ring.recordEnqueue(.mainActor, priority: 21) == 1)
        #expect(ring.recordEnqueue(.mainActor, priority: 21) == nil, "past capacity")
        ring.recordRun(slot: 0, nanos: 5)
        let read = ring.read()
        #expect(read.jobs.map(\.slot) == [0])
        #expect(read.pending == 1, "claimed, not run yet")
        #expect(read.dropped == 1)
    }

    @Test func recordsTheEnqueuersStackPriorityAndTimes() throws {
        let ticks = Ticks()
        ticks.set(1_000)
        let ring = MainJobRing(capacity: 4) { ticks.read() }
        let slot = try #require(ring.recordEnqueue(.mainDelivery, priority: 0x11))
        ring.recordRun(slot: slot, nanos: 300)
        let job = try #require(ring.read().jobs.first)
        #expect(job.kind == .mainDelivery)
        #expect(job.enqueuedNanos == 1_000)
        #expect(job.runNanos == 300)
        #expect(job.priority == 0x11)
        #expect(!job.frames.isEmpty && job.frames.count <= MainJobRing.depth)
    }

    @Test func theTallyHoldsTheJobsSinceTheLastTake() {
        let ring = MainJobRing(capacity: 4)
        let first = ring.recordEnqueue(.mainActor, priority: 21), second = ring.recordEnqueue(.mainActor, priority: 21)
        ring.recordRun(slot: first ?? -1, nanos: 3)
        ring.recordRun(slot: second ?? -1, nanos: 7)
        let tally = ring.takeTally()
        #expect((tally.jobs, tally.nanos, tally.longestSlot, tally.longestNanos) == (2, 10, second, 7))
        #expect(ring.takeTally() == MainJobRing.Tally())
    }

    @Test func nothingIsRecordedAfterFreeze() {
        let ring = MainJobRing(capacity: 4)
        ring.freeze()
        #expect(ring.recordEnqueue(.mainActor, priority: 21) == nil)
        #expect(ring.read().jobs.isEmpty && ring.read().dropped == 0, "a frozen ring drops nothing it did not claim")
    }

    @MainActor @Test func aTimedDeliveryRunsItsWorkAndRecordsItsRunTime() throws {
        let ticks = Ticks()
        ticks.set(10_000)
        let ring = MainJobRing(capacity: 4) { ticks.read() }
        let work = ring.timed { ticks.set(10_250) }
        work()
        let job = try #require(ring.read().jobs.first)
        #expect((job.kind, job.enqueuedNanos, job.runNanos) == (MainJobRing.Kind.mainDelivery, UInt64(10_000), UInt64(250)))
    }

    @MainActor @Test func aFrozenRingLeavesADeliveryAsItIs() {
        let ticks = Ticks()
        let ring = MainJobRing(capacity: 4) { ticks.read() }
        ring.freeze()
        let work = ring.timed { ticks.set(42) }
        work()
        #expect(ticks.read() == 42)
        #expect(ring.read().jobs.isEmpty)
    }
}
#endif
