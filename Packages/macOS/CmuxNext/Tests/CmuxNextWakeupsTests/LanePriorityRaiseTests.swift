import CmuxNextCompat
@testable import CmuxNextWakeups
import Darwin
import Dispatch
import Testing

/// `WorkHandle.raise(to:)` (plans/cmux-next/chrome-parity/p02-threads.md, task 117): a queued item moves to the
/// higher list and starts before the lower items queued with it; a running item gets one QoS override of its
/// slot thread, ended when it finishes; an equal or lower raise does nothing. Chrome's
/// `UpdateableSequencedTaskRunner::UpdatePriority` and `ScopedBoostablePriority`.
///
/// Every lane here has one slot (`cpuWidth: 1`), held by a blocker until the test has queued and raised.
@Suite(.timeLimit(.minutes(1))) struct LanePriorityRaiseTests {
    /// Lane bodies (synchronous) report; the async test awaits the reports.
    struct Signal: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream.makeStream(of: Void.self) }

        func send() { continuation.yield() }

        func wait(_ count: Int) async {
            var left = count
            guard left > 0 else { return }
            for await _ in stream {
                left -= 1
                if left == 0 { return }
            }
        }
    }

    /// The order lane bodies ran in.
    final class RunOrder: Sendable {
        private let names = Mutex<[String]>([])
        let ran = Signal()

        func record(_ name: String) {
            names.withLock { $0.append(name) }
            ran.send()
        }

        var order: [String] { names.withLock { $0 } }
    }

    /// A ``ThreadQoSOverride`` that records its calls instead of calling the kernel.
    final class OverrideLog: Sendable {
        enum Event: Equatable, Sendable {
            case start(thread: mach_port_t, priority: WorkPriority, token: UInt)
            case end(token: UInt)
        }

        private let events = Mutex<[Event]>([])
        let ended = Signal()

        var recorded: [Event] { events.withLock { $0 } }

        var hook: ThreadQoSOverride {
            ThreadQoSOverride(
                start: { [self] thread, priority in
                    let token = events.withLock { events -> UInt in
                        let token = UInt(events.count + 1)
                        events.append(.start(thread: thread, priority: priority, token: token))
                        return token
                    }
                    return ThreadQoSOverride.Token(raw: token)
                },
                end: { [self] token in
                    events.withLock { $0.append(.end(token: token.raw)) }
                    ended.send()
                })
        }
    }

    /// The Mach port of the thread a lane body ran on.
    final class ThreadPort: Sendable {
        private let port = Mutex<mach_port_t>(0)

        func recordCurrent() { port.withLock { $0 = pthread_mach_thread_np(pthread_self()) } }

        var value: mach_port_t { port.withLock { $0 } }
    }

    private func oneSlotWork(_ label: String, queued: Signal, overrides: OverrideLog = OverrideLog()) -> BackgroundWork {
        BackgroundWork(cpuWidth: 1, label: label, onQueued: { lane, _ in if lane == .cpu { queued.send() } },
                       uptimeNanos: nil, taskHooks: .none, qosOverride: overrides.hook)
    }

    @Test func aRaisedQueuedItemStartsBeforeFiveOthers() async throws {
        let queued = Signal(), runs = RunOrder(), release = DispatchSemaphore(value: 0)
        let work = oneSlotWork("test.raise-queued", queued: queued)
        work.post(.userBlocking, mayBlock: .cpu) { release.wait() }
        for index in 0..<5 {
            work.post(.bestEffort, mayBlock: .cpu) { runs.record("posted \(index)") }
        }
        let handle = work.runHandle(.bestEffort, mayBlock: .cpu) { () throws -> Int in
            runs.record("raised")
            return 1
        }
        await queued.wait(6)
        handle.raise(to: .userBlocking)
        release.signal()
        await runs.ran.wait(6)
        #expect(runs.order == ["raised"] + (0..<5).map { "posted \($0)" })
        #expect(try await handle.value == 1)
    }

    @Test func anEqualOrLowerRaiseLeavesAQueuedItemInPlace() async throws {
        let queued = Signal(), runs = RunOrder(), release = DispatchSemaphore(value: 0), overrides = OverrideLog()
        let work = oneSlotWork("test.raise-equal", queued: queued, overrides: overrides)
        work.post(.userBlocking, mayBlock: .cpu) { release.wait() }
        for index in 0..<2 {
            work.post(.userVisible, mayBlock: .cpu) { runs.record("posted \(index)") }
        }
        let handle = work.runHandle(.userVisible, mayBlock: .cpu) { () throws -> Int in
            runs.record("handle")
            return 2
        }
        await queued.wait(3)
        handle.raise(to: .userVisible)
        handle.raise(to: .bestEffort)
        handle.raise(to: .idle)
        release.signal()
        await runs.ran.wait(3)
        #expect(runs.order == ["posted 0", "posted 1", "handle"])
        #expect(try await handle.value == 2)
        #expect(overrides.recorded.isEmpty)
    }

    @Test func raisingARunningItemStartsOneOverrideOnItsThreadAndEndsIt() async throws {
        let queued = Signal(), started = Signal(), release = DispatchSemaphore(value: 0)
        let overrides = OverrideLog(), thread = ThreadPort()
        let work = oneSlotWork("test.raise-running", queued: queued, overrides: overrides)
        let handle = work.runHandle(.bestEffort, mayBlock: .cpu) { () throws -> Int in
            thread.recordCurrent()
            started.send()
            release.wait()
            return 3
        }
        await started.wait(1)
        handle.raise(to: .userBlocking)
        // Equal and lower raises of a running item start nothing more.
        handle.raise(to: .userBlocking)
        handle.raise(to: .userVisible)
        #expect(overrides.recorded == [.start(thread: thread.value, priority: .userBlocking, token: 1)])
        release.signal()
        #expect(try await handle.value == 3)
        await overrides.ended.wait(1)
        #expect(overrides.recorded == [.start(thread: thread.value, priority: .userBlocking, token: 1), .end(token: 1)])
    }

    @Test func aRunningItemThatIsNeverRaisedGetsNoOverride() async throws {
        let queued = Signal(), overrides = OverrideLog(), runs = RunOrder()
        let work = oneSlotWork("test.raise-none", queued: queued, overrides: overrides)
        let handle = work.runHandle(.userBlocking, mayBlock: .cpu) { () throws -> Int in 4 }
        #expect(try await handle.value == 4)
        // The slot frees after the value resumes; a later item on the one slot runs only after that.
        work.post(.userBlocking, mayBlock: .cpu) { runs.record("after") }
        await runs.ran.wait(1)
        #expect(overrides.recorded.isEmpty)
    }

    @Test func cancellingAQueuedHandleThrowsCancellationAndNeverRunsIt() async throws {
        let queued = Signal(), runs = RunOrder(), release = DispatchSemaphore(value: 0)
        let work = oneSlotWork("test.raise-cancel", queued: queued)
        work.post(.userBlocking, mayBlock: .cpu) { release.wait() }
        let handle = work.runHandle(.bestEffort, mayBlock: .cpu) { () throws -> Int in
            runs.record("cancelled")
            return 5
        }
        await queued.wait(1)
        handle.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await handle.value }
        work.post(.userBlocking, mayBlock: .cpu) { runs.record("after") }
        await runs.ran.wait(1)
        #expect(runs.order == ["after"])
    }

    /// A plain post/run item is not raisable: it records no thread and a raise of it while it runs starts no override.
    @Test func raisingARunningPlainItemStartsNoOverride() async {
        let started = Signal(), finished = Signal(), release = DispatchSemaphore(value: 0), overrides = OverrideLog()
        let lane = LaneScheduler(label: "test.raise-plain", policy: .shared(width: 1), mayBlock: true,
                                 qosOverride: overrides.hook)
        let job = LaneJob(id: 1, shutdown: .skipOnShutdown, work: { _ in
            started.send()
            release.wait()
        }, abandoned: {}, done: { finished.send() })
        _ = lane.submit(job, at: .bestEffort, posted: true, unless: { false })
        await started.wait(1)
        lane.raise(1, to: .userBlocking, awaited: true)
        release.signal()
        await finished.wait(1)
        #expect(overrides.recorded.isEmpty)
    }

    /// An awaited item is never held by the best-effort fence, even when the awaiter's priority does not raise it.
    @Test func anAwaitedRaiseFreesAFencedItemWithoutMovingIt() async {
        let runs = RunOrder()
        let lane = LaneScheduler(label: "test.raise-fence", policy: .shared(width: 1), mayBlock: true)
        lane.fence()
        let job = LaneJob(id: 1, shutdown: .skipOnShutdown, work: { _ in runs.record("fenced") }, abandoned: {}, done: {})
        _ = lane.submit(job, at: .bestEffort, posted: true, unless: { false })
        lane.raise(1, to: .idle, awaited: true)
        await runs.ran.wait(1)
        #expect(runs.order == ["fenced"])
        lane.unfence()
    }

    @Test func theSystemOverrideStartsAndEndsOnALiveThread() {
        let override = ThreadQoSOverride.system
        let token = override.start(pthread_mach_thread_np(pthread_self()), .userBlocking)
        #expect(token != nil)
        if let token { override.end(token) }
    }
}
