#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Testing

/// The main-job census's ring: bounded, the enqueuer's stack, priority and label per job, timed runs
/// of every kind, and nothing recorded once frozen. A test ring is never installed as the runtime's hook.
struct MainJobRingTests {
    /// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds). Nonisolated: the ring reads its clock on the enqueuing
    /// thread, from a `@Sendable` closure, and the atomic makes it safe from any thread.
    nonisolated final class Ticks: Sendable {
        let value = Atomic<UInt64>(0)
        func set(_ nanos: UInt64) { value.store(nanos, ordering: .relaxed) }
        func read() -> UInt64 { value.load(ordering: .relaxed) }
    }

    @Test func keepsTheFirstJobsAndCountsTheRestAsDropped() {
        let ring = MainJobRing(capacity: 2)
        #expect(ring.recordEnqueue(.mainActor, priority: 25) == 0)
        #expect(ring.recordEnqueue(.mainActor, priority: 21) == 1)
        #expect(ring.recordEnqueue(.mainActor, priority: 21) == nil, "past capacity")
        ring.recordRun(slot: 0, startNanos: 1, nanos: 5)
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
        ring.recordRun(slot: slot, startNanos: 1_200, nanos: 300)
        let job = try #require(ring.read().jobs.first)
        #expect(job.kind == .mainDelivery)
        #expect((job.enqueuedNanos, job.runStartNanos, job.runNanos) == (1_000, 1_200, 300))
        #expect(job.priority == 0x11)
        #expect(job.label == nil)
        #expect(!job.frames.isEmpty && job.frames.count <= MainJobRing.depth)
    }

    @Test func theTallyHoldsTheJobsSinceTheLastTake() {
        let ring = MainJobRing(capacity: 4)
        let first = ring.recordEnqueue(.mainActor, priority: 21), second = ring.recordEnqueue(.mainActor, priority: 21)
        ring.recordRun(slot: first ?? -1, startNanos: 0, nanos: 3)
        ring.recordRun(slot: second ?? -1, startNanos: 3, nanos: 7)
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
        #expect((job.kind, job.enqueuedNanos, job.runStartNanos, job.runNanos)
            == (MainJobRing.Kind.mainDelivery, UInt64(10_000), UInt64(10_000), UInt64(250)))
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

    /// A `MainRunLoopBlock` post claims a `runLoopBlock` slot where it posts, with that site's stack, and its run is
    /// timed when the run loop runs it.
    @MainActor @Test func aRunLoopBlockPostIsTimedWithItsPostSitesStack() throws {
        let ticks = Ticks()
        ticks.set(5_000)
        let ring = MainJobRing(capacity: 4) { ticks.read() }
        let slot = try #require(ring.recordEnqueue(.runLoopBlock, priority: MainJobRing.currentPriority))
        ticks.set(6_000)
        ring.run(slot: slot) { ticks.set(6_400) }
        let job = try #require(ring.read().jobs.first)
        #expect((job.kind, job.enqueuedNanos, job.runStartNanos, job.runNanos)
            == (MainJobRing.Kind.runLoopBlock, UInt64(5_000), UInt64(6_000), UInt64(400)))
        #expect(job.label == nil && !job.frames.isEmpty)
        #expect(ring.takeTally().jobs == 1)
    }

    /// A timer fire is labeled with its owner; the main-actor jobs it enqueues take the label, a run-loop block it
    /// posts (whose stack names its own site) does not, and the label ends with the fire.
    @MainActor @Test func aTimerFireLabelsItselfAndTheMainActorJobsItEnqueues() throws {
        let ring = MainJobRing(capacity: 8)
        let fire = try #require(ring.recordEnqueue(.timer, priority: 0x15, label: "Sidebar.refresh"))
        var inner: (task: Int?, block: Int?) = (nil, nil)
        ring.run(slot: fire) {
            inner = (ring.recordEnqueue(.mainActor, priority: 0x15), ring.recordEnqueue(.runLoopBlock, priority: 0x15))
        }
        let task = try #require(inner.task), block = try #require(inner.block)
        let after = try #require(ring.recordEnqueue(.mainActor, priority: 0x15))
        for slot in [task, block, after] { ring.recordRun(slot: slot, startNanos: 0, nanos: 1) }
        let jobs = ring.read().jobs
        func label(_ slot: Int) -> String? { jobs.first { $0.slot == slot }?.label }
        #expect(jobs.count == 4)
        #expect(label(fire) == "Sidebar.refresh")
        #expect(label(task) == "Sidebar.refresh")
        #expect(label(block) == nil)
        #expect(label(after) == nil)
    }

    @Test func theEnqueueRuntimeTablesNameTheConcurrencyRuntime() {
        #expect(MainJobRing.enqueueRuntimeImages.contains(MainJobRing.concurrencyRuntimeImage))
        #expect(MainJobRing.enqueueRuntimeImages.contains("libswiftDispatch.dylib"))
        #expect(MainJobRing.enqueueRuntimeSymbolPrefixes == ["$sScT", "$sScM"])
    }
}
#endif
