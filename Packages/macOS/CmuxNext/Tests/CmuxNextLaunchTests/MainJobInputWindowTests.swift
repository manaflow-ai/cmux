#if DEBUG || CMUX_BENCH_HOOKS
@testable import CmuxNextCompat
@testable import CmuxNextLaunch
import Testing

/// The main-job census's input window (sequence-manager S6): a continuous ring reuses its slots only after their jobs
/// ran, and each key's dispatch keeps the main jobs that ran between the key's arrival and its dispatch, which the
/// report names by enqueue site. The ring here is never installed: the tests record and run jobs themselves.
@MainActor struct MainJobInputWindowTests {
    private static let ms: UInt64 = 1_000_000

    /// A clock the test moves. Nonisolated: the ring reads its clock from a `@Sendable` closure.
    nonisolated final class Clock: Sendable {
        let value = Atomic<UInt64>(0)
        var now: UInt64 {
            get { value.load(ordering: .relaxed) }
            set { value.store(newValue, ordering: .relaxed) }
        }
    }

    /// Records and runs one job of `kind` that runs from `start` for `run` milliseconds.
    private static func ranJob(_ ring: MainJobRing, _ clock: Clock, _ kind: MainJobRing.Kind = .mainActor,
                               label: String? = nil, start: UInt64, run: UInt64) {
        clock.now = start * ms
        guard let slot = ring.recordEnqueue(kind, priority: 0x19, label: label) else {
            Issue.record("no slot")
            return
        }
        ring.run(slot: slot) { clock.now = (start + run) * ms }
    }

    @Test func aContinuousRingReusesASlotOnlyAfterItsJobRan() throws {
        let clock = Clock()
        let ring = MainJobRing(capacity: 2, continuous: true) { clock.now }
        let first = try #require(ring.recordEnqueue(.mainActor, priority: 0))
        let second = try #require(ring.recordEnqueue(.mainActor, priority: 0))
        #expect(ring.recordEnqueue(.mainActor, priority: 0) == nil, "slot 0's job has not run")
        #expect(ring.busyDrops == 1)
        ring.run(slot: first) {}
        #expect(ring.recordEnqueue(.mainActor, priority: 0) == nil, "the claim moved on to slot 1, still busy")
        ring.run(slot: second) {}
        #expect(ring.recordEnqueue(.mainActor, priority: 0) == first, "the freed slot is claimed again")
        #expect(ring.read().jobs.isEmpty, "a continuous ring has no launch list")
    }

    @Test func aDispatchKeepsTheJobsThatOverlapItsWait() {
        let clock = Clock()
        let ring = MainJobRing(capacity: 64, continuous: true) { clock.now }
        Self.ranJob(ring, clock, start: 1, run: 1)            // ended before the key arrived: not kept
        Self.ranJob(ring, clock, start: 4, run: 2)            // running when the key arrived at 5: 1 ms inside
        Self.ranJob(ring, clock, .runLoopBlock, start: 6, run: 3)
        Self.ranJob(ring, clock, .timer, label: "Sidebar.refresh", start: 9, run: 1)
        ring.noteInputDispatch(eventNanos: 5 * Self.ms, dispatchNanos: 10 * Self.ms)
        ring.noteInputDispatch(eventNanos: 12 * Self.ms, dispatchNanos: 11 * Self.ms) // a clock it cannot order: no wait
        let window = ring.readInputWindow()
        #expect(window.events.count == 2)
        #expect(window.jobs.map(\.event) == [0, 0, 0])
        #expect(window.jobs.map(\.job.kind) == [.timer, .runLoopBlock, .mainActor], "newest first")
        #expect(window.jobs.map(\.inWindowNanos) == [Self.ms, 3 * Self.ms, Self.ms])
        #expect(window.jobs.first?.job.label == "Sidebar.refresh")
        ring.resetInputWindow()
        #expect(ring.readInputWindow().events.isEmpty && ring.readInputWindow().jobs.isEmpty)
    }

    @Test func aRingThatIsNotContinuousKeepsNoWindow() throws {
        let ring = MainJobRing(capacity: 4) { 0 }
        let slot = try #require(ring.recordEnqueue(.mainActor, priority: 0))
        ring.run(slot: slot) {}
        ring.noteInputDispatch(eventNanos: 0, dispatchNanos: 1)
        #expect(ring.readInputWindow().events.isEmpty)
        #expect(ring.read().jobs.count == 1)
    }

    @Test func theReportCountsUnpostedJobsPerEventAndRanksSitesByTheirTimeInTheWait() throws {
        func job(_ kind: MainJobRing.Kind, frames: [UInt], label: String? = nil, run: UInt64) -> MainJobRing.Job {
            MainJobRing.Job(slot: 0, kind: kind, enqueuedNanos: 0, runStartNanos: 0, runNanos: run * Self.ms, priority: 0x19,
                            label: label, frames: frames)
        }
        let feed = job(.mainActor, frames: [1], run: 2), reply = job(.mainActor, frames: [2], run: 1)
        let block = job(.runLoopBlock, frames: [3], run: 4)
        let window = MainJobRing.InputWindow(
            events: [.init(arrivalNanos: 0, dispatchNanos: 8 * Self.ms), .init(arrivalNanos: 10 * Self.ms, dispatchNanos: 11 * Self.ms),
                     .init(arrivalNanos: 20 * Self.ms, dispatchNanos: 20 * Self.ms)],
            jobs: [.init(event: 0, job: feed, inWindowNanos: 2 * Self.ms), .init(event: 0, job: reply, inWindowNanos: Self.ms),
                   .init(event: 0, job: block, inWindowNanos: 4 * Self.ms), .init(event: 1, job: feed, inWindowNanos: Self.ms)],
            droppedEvents: 0, droppedJobs: 0, busyDrops: 3)
        var stacks = 0
        let entry = MainJobCensusReport.Frame(image: MainJobRing.concurrencyRuntimeImage, symbol: "swift_task_enqueueMainExecutor", imageOffset: 1)
        let report = MainJobInputReport(window) { frames in
            stacks += 1
            let name = ["", "HomeFeed.apply()", "DaemonReply.resume()", "Sidebar.reload()"][Int(frames[0])]
            return [entry, .init(image: "cmux", symbol: name, imageOffset: frames[0])]
        }
        #expect(stacks == 3, "each distinct stack is resolved once")
        #expect(report.summary.events == 3 && report.summary.eventsWithJobs == 2)
        #expect(report.summary.jobs == 4 && report.summary.unpostedJobs == 3)
        #expect(report.summary.unpostedPerEvent.max == 2 && report.summary.unpostedPerEvent.p50 == 1)
        #expect(report.summary.unpostedMsPerEvent.max == 3)
        #expect(report.summary.waitMs.max == 8 && report.summary.waitMs.n == 3)
        #expect(report.summary.busyDrops == 3)
        #expect(report.sites.map(\.caller) == ["Sidebar.reload()", "HomeFeed.apply()", "DaemonReply.resume()"])
        #expect(report.sites.map(\.kind) == ["run_loop_block", "main_actor", "main_actor"])
        let home = try #require(report.sites.first { $0.caller == "HomeFeed.apply()" })
        #expect((home.jobs, home.events, home.inWindowMs, home.maxRunMs) == (2, 2, 3, 2))
        let object = try #require(try report.foundationObject() as? [String: Any])
        #expect(Set(object.keys) == ["main_job_input", "sites"])
    }

    @Test func aContinuousRingIsTheInputWindow() {
        #expect(MainJobCensus.inputWindowValue == "input")
        let ring = MainJobRing(capacity: 4, continuous: true) { 0 }
        let census = MainJobCensus(ring: ring, hook: .installed, processStartNanos: 0)
        #expect(census.isInputWindow)
        #expect(!MainJobCensus(ring: MainJobRing(capacity: 4) { 0 }, hook: .installed, processStartNanos: 0).isInputWindow)
    }
}
#endif
