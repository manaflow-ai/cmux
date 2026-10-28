import CmuxNextCompat
import Testing
@testable import CmuxNextWakeups
import CmuxNextWakeupsTestSupport

/// The MainJobGate's classes (plans/cmux-next/chrome-parity/p04-input.md, task 076): a job made on
/// the main thread outside input waits while input is pending; one made in an event's dispatch,
/// by `MainWork.input` or `MainWork.frame` passes; priority never decides; held jobs keep their
/// order and every later job queues behind them; the one-refresh deadline releases them all.
@MainActor @Suite(.timeLimit(.minutes(1))) struct MainJobGateClassTests {
    /// Jobs as the runtime hands them out: at least 16-byte aligned.
    nonisolated static func job(_ n: UInt) -> MainJobGate.Entry {
        MainJobGate.Entry(job: n << 4, original: 0, priority: 21)
    }

    /// A `Task {}` made on main while a key is pending, outside any dispatch, is held.
    @Test func mainTaskOutsideInputIsHeld() {
        let rig = GateRig()
        rig.state.publish(.key)
        rig.gate.enqueue(Self.job(1))
        #expect(rig.forwarded.jobs.isEmpty)
        #expect(rig.gate.heldCount == 1)
        #expect(rig.state.bits.contains(.held))
        #expect(rig.gate.counters.heldByOrigin == ["main": 1, "off_main": 0])
        #expect(rig.wakes.count == 1, "the first held job wakes the main run loop")
    }

    /// With nothing pending and nothing held, every job passes and nothing is counted.
    @Test func quietWordPassesEverything() {
        let rig = GateRig()
        rig.gate.enqueue(Self.job(1))
        rig.gate.enqueue(Self.job(2))
        #expect(rig.forwarded.jobs == [Self.job(1).job, Self.job(2).job])
        #expect(rig.gate.counters.exemptByRule.values.allSatisfy { $0 == 0 })
        #expect(rig.wakes.count == 0)
    }

    /// The same job enqueued on main inside an event's route passes (in_dispatch); off main it is held.
    @Test func jobInsideRoutePasses() {
        let rig = GateRig()
        rig.state.publish(.key)
        let outer = rig.state.beginDispatch()
        rig.gate.enqueue(Self.job(1))
        rig.gate.enqueue(Self.job(2), bits: rig.state.bits, onMain: false)
        rig.state.endDispatch(restoring: outer)
        #expect(rig.forwarded.jobs == [Self.job(1).job])
        #expect(rig.gate.heldCount == 1)
        #expect(rig.gate.counters.exemptByRule["in_dispatch"] == 1)
        #expect(!rig.state.bits.contains(.dispatching))
    }

    /// A nested dispatch keeps the outer one marked.
    @Test func nestedDispatchKeepsOuterMark() {
        let state = InputPendingState()
        let outer = state.beginDispatch()
        let inner = state.beginDispatch()
        state.endDispatch(restoring: inner)
        #expect(state.bits.contains(.dispatching))
        state.endDispatch(restoring: outer)
        #expect(!state.bits.contains(.dispatching))
    }

    /// MainWork.input's task passes at its creation and at every later enqueue (an await's
    /// resumption, from any thread) until its body returns; MainWork.frame the same.
    @Test func mainWorkStampedTasksPass() {
        let rig = GateRig()
        rig.state.publish(.key)
        rig.gate.stamping(.input) { rig.gate.enqueue(Self.job(1)) }
        rig.gate.stamping(.frame) { rig.gate.enqueue(Self.job(2)) }
        rig.gate.enqueue(Self.job(1), bits: rig.state.bits, onMain: false)
        rig.gate.enqueue(Self.job(2))
        #expect(rig.forwarded.jobs == [Self.job(1).job, Self.job(2).job, Self.job(1).job, Self.job(2).job])
        #expect(rig.gate.counters.exemptByRule["main_work_input"] == 2)
        #expect(rig.gate.counters.exemptByRule["main_work_frame"] == 2)
        rig.gate.unstamp(Self.job(1).job)
        rig.gate.enqueue(Self.job(1))
        #expect(rig.gate.heldCount == 1, "a finished MainWork task's address is an ordinary job again")
    }

    /// The real MainWork API stamps its running task and drops the stamp when the body returns.
    @Test func mainWorkStampsItsRunningTask() async throws {
        let rig = GateRig()
        let work = MainWork(gate: rig.gate)
        let gate = rig.gate
        let stamped = ForwardedJobs()
        await work.input {
            if let job = MainWork.currentJob(), gate.isStamped(job) { stamped.append(job) }
        }.value
        let job = try #require(stamped.jobs.first, "the body runs with its own task stamped")
        #expect(!gate.isStamped(job), "the stamp goes when the body returns")
        #expect(rig.gate.counters.stampOverflow == 0)
        #expect(!rig.state.bits.contains(.stampingInput), "the creation flag is down once the task is made")
    }

    /// Priority never decides: an escalated (high) job and a background one are both held, in order.
    @Test func escalatedJobIsStillHeld() {
        let rig = GateRig()
        rig.state.publish(.click)
        var high = Self.job(1)
        high.priority = UInt8(TaskPriority.high.rawValue)
        var low = Self.job(2)
        low.priority = UInt8(TaskPriority.background.rawValue)
        rig.gate.enqueue(low)
        rig.gate.enqueue(high)
        #expect(rig.forwarded.jobs.isEmpty)
        rig.gate.releaseAll(.drained)
        #expect(rig.forwarded.jobs == [low.job, high.job])
    }

    /// While anything is held, a job enqueued after the input is gone still queues behind it; the
    /// first job after the FIFO empties passes at once, after every released one.
    @Test func jobAfterReleaseRunsAfterHeldJobs() {
        let rig = GateRig()
        rig.state.publish(.key)
        rig.gate.enqueue(Self.job(1))
        rig.gate.enqueue(Self.job(2), bits: rig.state.bits, onMain: false)
        rig.state.publish([])
        rig.gate.enqueue(Self.job(3))
        #expect(rig.forwarded.jobs.isEmpty, "no job overtakes the held ones")
        #expect(rig.gate.forwardOldest())
        #expect(rig.gate.forwardOldest())
        #expect(rig.gate.forwardOldest())
        #expect(!rig.gate.forwardOldest())
        #expect(!rig.state.bits.contains(.held))
        rig.gate.enqueue(Self.job(4))
        #expect(rig.forwarded.jobs == [1, 2, 3, 4].map { Self.job($0).job })
        #expect(rig.gate.counters.releasedBy["drained"] == 3)
        #expect(rig.gate.counters.heldByOrigin == ["main": 2, "off_main": 1])
    }

    /// The deadline on a manual clock: nothing goes before one refresh after the first held job,
    /// then the whole FIFO goes in order.
    @Test func deadlineReleasesWholeFIFOInOrder() {
        let clock = ManualClock()
        let rig = GateRig(clock: clock)
        let refresh: UInt64 = 16_666_667
        rig.state.publish(.key)
        rig.gate.enqueue(Self.job(1))
        clock.advance(by: .milliseconds(10))
        rig.gate.enqueue(Self.job(2))
        #expect(!rig.gate.releaseIfOverdue(refreshNanos: refresh))
        clock.advance(by: .milliseconds(6))
        #expect(!rig.gate.releaseIfOverdue(refreshNanos: refresh))
        clock.advance(by: .milliseconds(1))
        #expect(rig.gate.releaseIfOverdue(refreshNanos: refresh))
        #expect(rig.forwarded.jobs == [Self.job(1).job, Self.job(2).job])
        #expect(rig.gate.counters.releasedBy["deadline"] == 2)
        rig.gate.enqueue(Self.job(3))
        clock.advance(by: .milliseconds(10))
        #expect(!rig.gate.releaseIfOverdue(refreshNanos: refresh), "a new hold starts its own deadline")
    }

    /// Stopping (the hook's uninstall) releases in order and passes everything after.
    @Test func stopReleasesAndPasses() {
        let rig = GateRig()
        rig.state.publish(.key)
        rig.gate.enqueue(Self.job(1))
        rig.gate.stop()
        rig.gate.enqueue(Self.job(2))
        #expect(rig.forwarded.jobs == [Self.job(1).job, Self.job(2).job])
        #expect(rig.gate.counters.releasedBy["uninstalled"] == 1)
        rig.gate.start()
        rig.gate.enqueue(Self.job(3))
        #expect(rig.gate.heldCount == 1)
    }

    /// A job that sees the uninstall's or the nested loop's bit while held jobs are not released
    /// yet (another thread between the bit and the release) queues behind them; the release sets
    /// the bit and empties the FIFO in one step.
    @Test func aJobDuringAReleaseQueuesBehindTheReleasedJobs() {
        for bit in [InputPendingState.Bits.bypass, .nestedLoop] {
            let rig = GateRig()
            rig.state.publish(.key)
            rig.gate.enqueue(Self.job(1))
            rig.state.insert(bit)
            rig.gate.enqueue(Self.job(2), bits: rig.state.bits, onMain: false)
            #expect(rig.forwarded.jobs.isEmpty, "\(bit): no job overtakes a held one")
            rig.state.remove(bit)
            if bit == .bypass { rig.gate.stop() } else { rig.gate.enterNestedLoop() }
            #expect(rig.forwarded.jobs == [Self.job(1).job, Self.job(2).job])
            #expect(rig.state.bits.contains(bit))
            #expect(!rig.state.bits.contains(.held))
            rig.gate.enqueue(Self.job(3), bits: rig.state.bits, onMain: false)
            #expect(rig.forwarded.jobs == [1, 2, 3].map { Self.job($0).job })
        }
    }

    /// A job held one refresh or more counts as deferred over one frame; one forwarded sooner does not.
    @Test func deferredOverOneFrameCountsLongHolds() {
        let clock = ManualClock()
        let rig = GateRig(clock: clock)
        rig.state.publish(.key)
        rig.gate.enqueue(Self.job(1))
        clock.advance(by: .milliseconds(10))
        rig.gate.enqueue(Self.job(2))
        clock.advance(by: .milliseconds(7))
        #expect(rig.gate.releaseIfOverdue(refreshNanos: 16_666_667))
        #expect(rig.gate.counters.deferredOverOneFrame == 1, "job 2 waited 7 ms")
        rig.gate.resetCounters()
        #expect(rig.gate.counters.deferredOverOneFrame == 0)
        #expect(rig.gate.counters.releasedBy.values.allSatisfy { $0 == 0 })
    }
}

/// A gate whose forwards and wakes are recorded, on the real clock or a manual one.
@MainActor
final class GateRig {
    let state: InputPendingState
    let forwarded: ForwardedJobs
    let wakes: ForwardedJobs
    let gate: MainJobGate

    init(clock: ManualClock? = nil) {
        let state = InputPendingState(), forwarded = ForwardedJobs(), wakes = ForwardedJobs()
        let now: @Sendable () -> UInt64
        if let clock { now = { GateRig.nanos(clock.now.offset) } } else { now = { MainTaskPost.uptimeNanos() } }
        (self.state, self.forwarded, self.wakes) = (state, forwarded, wakes)
        gate = MainJobGate(state: state, forward: { forwarded.append($0.job) }, uptimeNanos: now, wakeMain: { wakes.append(0) })
    }

    nonisolated static func nanos(_ duration: Duration) -> UInt64 {
        let parts = duration.components
        return UInt64(parts.seconds) * 1_000_000_000 + UInt64(parts.attoseconds / 1_000_000_000)
    }
}

/// Jobs in the order they were forwarded (any thread).
final class ForwardedJobs: Sendable {
    // concurrency-allow: the test's record of forwarded jobs, appended by the gate's forward from any thread (lock carve-out: one array append or copy).
    private let recorded = Mutex<[UInt]>([])

    func append(_ job: UInt) { recorded.withLock { $0.append(job) } }
    var jobs: [UInt] { recorded.withLock { $0 } }
    var count: Int { jobs.count }
}
