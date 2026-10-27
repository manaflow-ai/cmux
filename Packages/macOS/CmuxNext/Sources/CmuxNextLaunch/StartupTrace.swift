import CmuxNextCompat
public import CmuxNextWakeups
import Darwin
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
public import Foundation

/// The startup trace (`CMUX_TRACE_STARTUP`): launch marks, startup tasks, main-thread turns over 1 ms,
/// ``BackgroundWork`` items and the daemon's prestart steps from process start to a deadline, written as a
/// Chrome Trace Event JSON file that ui.perfetto.dev loads (plans/cmux-next/chrome-parity/p08-startup.md,
/// task 004). Chrome's startup tracing (`--trace-startup`, components/tracing/common/trace_startup_config.cc):
/// a ring set up before anything else runs, recorded into while startup runs, flushed to a file, and closed
/// at the deadline.
///
/// Recording appends a fixed-size record to a preallocated ring under a short lock. One ``WorkSequence`` on the
/// files lane of the ``BackgroundWork`` given to ``start(writingOn:)`` drains the ring into the file in writes of about
/// 64 KiB, each ending on an event: when the ring holds a write's worth, and at most
/// ``StartupTraceConfiguration/flushInterval`` after a record that has not been written yet (Chrome's startup
/// tracing also flushes on a period), so a launch that crashes leaves a file that still loads with what it
/// recorded until shortly before (the JSON Array form needs no closing `]`). Nothing is written on the
/// recording thread, the main thread included.
///
/// Built only when the variable asks for it (``fromEnvironment(processStartNanos:)``); unset, the app holds
/// nil and records nothing.
///
/// ```swift
/// let trace = StartupTrace.fromEnvironment(processStartNanos: start)   // first thing in main
/// let work = BackgroundWork(onRan: trace?.laneJobSink)
/// trace?.start(writingOn: work)
/// trace?.mark("main_start")
/// ```
public final class StartupTrace: Sendable {
    /// Turns of the main run loop shorter than this are not recorded.
    public static let mainTurnThresholdNanos: UInt64 = 1_000_000

    public let configuration: StartupTraceConfiguration
    /// `CLOCK_UPTIME_RAW` nanoseconds at process start; the deadline counts from it.
    public let processStartNanos: UInt64
    /// The bytes the ring holds while recording (both halves of its double buffer).
    public let ringBytes: Int
    private let now: @Sendable () -> UInt64
    private let deadline: DemandTimer
    /// The periodic drain: armed by the first record not yet written, at most one at a time.
    private let flushTimer: DemandTimer
    /// Recording until the trace closes: one load, so a closed trace costs its callers no lock.
    private let recording = Atomic<Bool>(true)
    // concurrency-allow: the ring's append and swap, held for one array append or one swap, never across I/O (lock carve-out: no I/O, no wait under it).
    private let state: Mutex<State>
    /// Records pending before a drain is posted: about one write's worth.
    private let drainCount: Int

    private struct State {
        var pending: [StartupTraceRecord]
        /// The other half of the double buffer, handed back after each drain with its capacity.
        var spare: [StartupTraceRecord]
        /// The file, taken out while a drain writes it.
        var file: StartupTraceFile?
        /// The drains, in post order and one at a time, on the files lane; nil before ``StartupTrace/start(writingOn:)``.
        var drains: WorkSequence?
        /// A posted drain has not started yet.
        var drainPosted = false
        /// ``StartupTrace/flushTimer`` is armed.
        var flushArmed = false
        /// Run once, on the files lane, after the file closes (``StartupTrace/whenClosed(_:)``).
        var closeHooks: [@Sendable () -> Void] = []
        /// The deadline passed (or ``StartupTrace/close()`` ran): the next drain closes the file.
        var closeRequested = false
        var dropped = 0
        var closed = false
    }

    /// The trace's status for `debug.startup_trace`.
    public struct Status: Sendable, Equatable {
        public var file: URL
        public var seconds: Double
        public var ringBytes: Int
        public var pending: Int
        public var dropped: Int
        /// Events in the file so far, metadata included.
        public var written: Int
        public var closed: Bool
        /// Why the file could not be written, if it could not.
        public var failure: String?
    }

    /// - Parameters:
    ///   - configuration: What to record, how long, and where.
    ///   - processStartNanos: `CLOCK_UPTIME_RAW` nanoseconds at process start.
    ///   - clock: The deadline's clock; tests inject a manual one.
    ///   - now: `CLOCK_UPTIME_RAW` nanoseconds now; tests inject their own.
    public init(configuration: StartupTraceConfiguration, processStartNanos: UInt64,
                clock: any Clock<Duration> = ContinuousClock(),
                now: (@Sendable () -> UInt64)? = nil) {
        self.configuration = configuration
        self.processStartNanos = processStartNanos
        self.now = now ?? { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
        deadline = DemandTimer(owner: "StartupTrace.deadline", clock: clock)
        flushTimer = DemandTimer(owner: "StartupTrace.flush", clock: clock)
        let capacity = configuration.capacity
        ringBytes = 2 * capacity * MemoryLayout<StartupTraceRecord>.stride
        drainCount = max(1, min(capacity / 2, configuration.chunkBytes / 160))
        var pending: [StartupTraceRecord] = [], spare: [StartupTraceRecord] = []
        pending.reserveCapacity(capacity)
        spare.reserveCapacity(capacity)
        state = Mutex(State(pending: pending, spare: spare,
                            file: StartupTraceFile(url: configuration.file, pid: getpid(), chunkBytes: configuration.chunkBytes,
                                                   mainThread: pthread_main_np() != 0 ? StartupTrace.threadID() : nil)))
    }

    /// The trace the environment asks for (`CMUX_TRACE_STARTUP`), or nil after one `getenv` when it is unset.
    /// `processStartNanos` is read only when the trace is on.
    public static func fromEnvironment(processStartNanos: @autoclosure () -> UInt64) -> StartupTrace? {
        guard let configuration = StartupTraceConfiguration.fromEnvironment(
            StartupTraceConfiguration.processEnvironment,
            home: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), pid: getpid()) else { return nil }
        return StartupTrace(configuration: configuration, processStartNanos: processStartNanos())
    }

    /// Starts writing on `work`'s files lane: opens the file now (off the caller's thread) and closes it
    /// ``StartupTraceConfiguration/seconds`` after process start.
    public func start(writingOn work: BackgroundWork) {
        let drains = work.sequence("startup-trace")
        state.withLock { $0.drains = drains }
        post(on: drains)
        let end = processStartNanos &+ UInt64(configuration.seconds * 1e9)
        let current = now()
        deadline.schedule(after: .nanoseconds(Int64(clamping: end > current ? end - current : 0))) { [self] in
            close()
        }
    }

    // MARK: recording

    /// A launch mark at `nanos` (`CLOCK_UPTIME_RAW`; default now), on the calling thread.
    public func mark(_ name: String, at nanos: UInt64? = nil) {
        let time = nanos ?? now()
        record(StartupTraceRecord(event: .mark(name), start: time, end: time, thread: Self.threadID()))
    }

    /// A startup task that ran from `start` to `end` (default now) on the calling thread.
    public func task(_ name: StaticString, start: UInt64, end: UInt64? = nil) {
        record(StartupTraceRecord(event: .task(name), start: start, end: end ?? now(), thread: Self.threadID()))
    }

    /// The trace's clock now (`CLOCK_UPTIME_RAW` nanoseconds): a startup task's start for ``task(_:start:end:)``.
    public var uptimeNanos: UInt64 { now() }

    /// A main-thread run-loop turn from `start` to `end` (the watchdog's main-turn sink, on the main thread).
    public func mainTurn(start: UInt64, end: UInt64) {
        record(StartupTraceRecord(event: .mainTurn, start: start, end: end, thread: Self.threadID()))
    }

    /// ``BackgroundWork``'s `onRan`: each item's lane, priority and run, recorded on its lane thread.
    public var laneJobSink: @Sendable (BlockingLane, WorkPriority, UInt64, UInt64) -> Void {
        { [self] lane, priority, start, end in
            record(StartupTraceRecord(event: .laneJob(lane, priority), start: start, end: end, thread: Self.threadID()))
        }
    }

    private func record(_ record: StartupTraceRecord) {
        guard recording.load(ordering: .relaxed) else { return }
        let next = state.withLock { state -> Next in
            guard !state.closed else { return .idle }
            if state.pending.count < configuration.capacity {
                state.pending.append(record)
            } else {
                state.dropped += 1
            }
            return nextDrain(&state)
        }
        run(next)
    }

    /// What to do after the ring changed: nothing, post a drain, or arm the periodic drain.
    private enum Next {
        case idle
        case drain(WorkSequence)
        case armFlush
    }

    /// A drain when a write's worth is pending, else the periodic drain for pending records; no periodic drain
    /// before ``start(writingOn:)`` (it posts the first drain) nor once a close is asked for (it posts the last).
    /// Under the state's lock.
    private func nextDrain(_ state: inout State) -> Next {
        guard let drains = state.drains, !state.closed, !state.drainPosted, !state.pending.isEmpty else { return .idle }
        if state.pending.count >= drainCount {
            state.drainPosted = true
            return .drain(drains)
        }
        guard !state.flushArmed, !state.closeRequested else { return .idle }
        state.flushArmed = true
        return .armFlush
    }

    private func run(_ next: Next) {
        switch next {
        case .idle: break
        case let .drain(drains): post(on: drains)
        case .armFlush:
            flushTimer.schedule(after: configuration.flushInterval) { [self] in flushDue() }
        }
    }

    /// The periodic drain's deadline: drains what is pending unless a drain is already posted.
    private func flushDue() {
        let drains = state.withLock { state -> WorkSequence? in
            state.flushArmed = false
            guard !state.closed, !state.drainPosted, !state.pending.isEmpty, let drains = state.drains else { return nil }
            state.drainPosted = true
            return drains
        }
        if let drains { post(on: drains) }
    }

    // MARK: writing

    /// Writes what the ring holds now, and returns the status after the write (`debug.startup_trace`).
    ///
    /// Posted to the drains' sequence, so it runs after every drain posted before it.
    public func flush() async -> Status {
        if let drains = state.withLock({ $0.drains }) {
            // A drain dropped unrun returns the status as it is.
            _ = try? await withOnceContinuation { (written: OnceContinuation<Void, OnceContinuationError>) in
                drains.post(.userVisible, shutdown: .blockShutdown) { [self] in
                    drain()
                    written.resume(returning: ())
                }
            }
        }
        return status
    }

    /// Runs `action` once, on the files lane, after the file closes (at once when it already closed): the
    /// producers' hooks come off then (the watchdog's main-turn sink, ``BackgroundWork/stopReportingRuns()``), so
    /// a closed trace costs the main thread and the lanes nothing. `action` must return at once.
    public func whenClosed(_ action: @escaping @Sendable () -> Void) {
        let closed = state.withLock { state -> Bool in
            if !state.closed { state.closeHooks.append(action) }
            return state.closed
        }
        if closed { action() }
    }

    /// Writes the rest and closes the file; later records are dropped. The deadline calls it; a second call
    /// does nothing.
    public func close() {
        guard let drains = state.withLock({ state -> WorkSequence? in
            guard !state.closeRequested, let drains = state.drains else { return nil }
            state.closeRequested = true
            return drains
        }) else { return }
        drains.post(.userVisible, shutdown: .blockShutdown) { [self] in drain() }
    }

    /// The trace's status now.
    public var status: Status {
        state.withLock { state in
            Status(file: configuration.file, seconds: configuration.seconds, ringBytes: ringBytes,
                   pending: state.pending.count, dropped: state.dropped, written: state.file?.events ?? 0,
                   closed: state.closed, failure: state.file?.failure)
        }
    }

    /// Posts a drain at `.userVisible`: below the person's input, and not held by the startup fence, which
    /// would keep the file empty until startup completes.
    private func post(on drains: WorkSequence) {
        drains.post(.userVisible) { [self] in drain() }
    }

    /// Runs on the files lane: swaps the ring's halves, writes the full half, hands it back; once a close
    /// was asked for, also writes the end of the file. Drains run one at a time (one sequence); a drain that
    /// finds the file taken anyway returns at once.
    private func drain() {
        let taken = state.withLock { state -> (batch: [StartupTraceRecord], file: StartupTraceFile, closing: Bool, dropped: Int)? in
            state.drainPosted = false
            guard !state.closed, let file = state.file else { return nil }
            let closing = state.closeRequested
            if closing {
                state.closed = true
                state.flushArmed = false
                recording.store(false, ordering: .relaxed)
            }
            var batch = state.spare
            state.spare = []
            swap(&batch, &state.pending)
            state.file = nil
            return (batch, file, closing, state.dropped)
        }
        guard let taken else { return }
        var batch = taken.batch, file = taken.file
        file.write(batch)
        if taken.closing { file.close(at: now(), dropped: taken.dropped) }
        batch.removeAll(keepingCapacity: true)
        let (next, hooks) = state.withLock { state -> (Next, [@Sendable () -> Void]) in
            state.file = file
            if state.closed {
                let hooks = state.closeHooks
                state.pending = []
                state.closeHooks = []
                return (.idle, hooks)
            }
            state.spare = batch
            return (nextDrain(&state), [])
        }
        if taken.closing {
            deadline.cancel()
            flushTimer.cancel()
        }
        for hook in hooks { hook() }
        run(next)
    }

    /// The calling thread's system-wide id (`pthread_threadid_np`), the `tid` Perfetto shows.
    static func threadID() -> UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        return id
    }
}
