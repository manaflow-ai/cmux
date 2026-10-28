import CmuxNextCompat
public import CmuxNextWakeups
import Darwin

extension StartupTrace {
    /// The field build's slow-launch ring (plans/cmux-next/chrome-parity/p08-startup.md task 111): with Nightly hang
    /// reports on, the launch's marks, startup tasks, main turns and lane jobs over 1 ms, by name and time only, in a
    /// 32 KiB ring from process start to `startup_complete`. At completion ``finish(keeping:)`` frees it; the app keeps
    /// its events only when the launch missed its p95 first-frame budget, and hands them to the hang report collector
    /// (CmuxNextHangReports' `HangReport.LaunchTrace`).
    ///
    /// Chrome's background tracing (content/browser/tracing/background_tracing_manager_impl.cc): a ring buffer
    /// (`RECORD_CONTINUOUSLY`) armed for a scenario, uploaded only when its trigger fires, else dropped. Unlike the
    /// developer trace (``StartupTrace``, `CMUX_TRACE_STARTUP`) it writes no file and holds no argument: a mark's,
    /// task's or lane's code-defined name, its times and whether it ran on the main thread.
    ///
    /// Recording takes a short lock for one array store, from any thread; a full ring overwrites its oldest record
    /// and counts it. Reports off, the app makes no ring (``forReports(optedIn:processStartNanos:)``): nothing is
    /// allocated and every producer hook stays off.
    ///
    /// The app makes it in `main()` and shares the producer hooks with the developer trace through
    /// ``StartupTrace/LaunchRecorders``, so freeing one never stops the other's records:
    ///
    /// ```swift
    /// let ring = StartupTrace.SlowLaunchRing.forReports(optedIn: consented, processStartNanos: start)  // in main
    /// let recorders = StartupTrace.LaunchRecorders(trace: startupTrace, ring: ring)
    /// let work = BackgroundWork(onRan: recorders.laneJobSink)
    /// recorders.whenAllStopped { work.stopReportingRuns() }
    /// // at startup_complete:
    /// let launch = ring?.finish(keeping: HangReport.LaunchTrace.exceedsBudget(record))
    /// let events = launch?.events(adding: startup.log.records)  // off the main thread
    /// ```
    public final class SlowLaunchRing: Sendable {
        /// The ring's size: 32 KiB of records.
        public static let defaultBytes = 32 * 1_024
        /// Startup tasks, main turns and lane jobs shorter than this are not recorded (marks always are).
        public static let sliceThresholdNanos: UInt64 = StartupTrace.mainTurnThresholdNanos

        /// `CLOCK_UPTIME_RAW` nanoseconds at process start: event times count from it.
        public let processStartNanos: UInt64
        /// The records the ring holds.
        public let capacity: Int
        /// The bytes the ring holds while recording.
        public let ringBytes: Int
        private let now: @Sendable () -> UInt64
        /// The main thread's id (``StartupTrace/threadID()``); nil when the ring was not made on it.
        private let mainThread: UInt64?
        /// Recording until ``finish(keeping:)``: one load, so a freed ring costs its producers no lock.
        private let recording = Atomic<Bool>(true)
        // concurrency-allow: the ring's one store per record and the take at completion, never across I/O or a wait (lock carve-out: no I/O, no wait under it).
        private let state: Mutex<State>

        private struct State {
            /// The records, in write order until the ring is full; then ``next`` is the oldest.
            var records: [StartupTraceRecord]
            /// The slot the next record overwrites once the ring is full.
            var next = 0
            /// Records overwritten by newer ones.
            var overwritten = 0
            /// ``SlowLaunchRing/finish(keeping:)`` ran: the records are gone and later ones are ignored.
            var freed = false
            /// Run once, after the ring is freed (``SlowLaunchRing/whenFreed(_:)``).
            var freedHooks: [@Sendable () -> Void] = []
        }

        /// One event of a kept launch: its kind, its code-defined name and its times from process start.
        public struct Event: Sendable, Equatable {
            /// What it was.
            public enum Kind: Sendable, Equatable, CaseIterable {
                /// A launch mark (an instant).
                case mark
                /// A startup task on the main thread.
                case mainTask
                /// A startup task on another thread.
                case laneTask
                /// A main run-loop turn.
                case mainTurn
                /// A ``BackgroundWork`` item on its lane.
                case laneJob
            }

            /// What it was.
            public var kind: Kind
            /// The mark's or task's name; `main.turn` for a main turn, `<lane>.<priority>` for a lane job.
            public var name: String
            /// Microseconds after process start.
            public var startMicros: UInt64
            /// Microseconds it ran; 0 for a mark.
            public var durationMicros: UInt64

            /// Makes the value from its parts.
            public init(kind: Kind, name: String, startMicros: UInt64, durationMicros: UInt64) {
                self.kind = kind
                self.name = name
                self.startMicros = startMicros
                self.durationMicros = durationMicros
            }
        }

        /// What ``finish(keeping:)`` hands over for a slow launch: the ring's records, oldest first. Its ``events``
        /// are built when read, so the caller builds them off the main thread.
        public struct Launch: Sendable {
            let records: [StartupTraceRecord]
            let processStartNanos: UInt64
            let mainThread: UInt64?
            /// Records the ring overwrote before completion.
            public let overwritten: Int

            /// The ring's events and `tasks`, the startup scheduler's records (``StartupTaskLog/records``): each task
            /// that ran 1 ms or more, a main task or a lane task by where it was posted. The scheduler keeps its own
            /// log, so its tasks never take the ring's room. Build it off the main thread.
            public func events(adding tasks: [StartupTaskLog.Record]) -> [Event] {
                events(adding: tasks.compactMap { task -> TaskSlice? in
                    guard let start = task.startNanos, let duration = task.durationNanos else { return nil }
                    return TaskSlice(name: task.name.description, onMain: task.destination == .main, startNanos: start, durationNanos: duration)
                })
            }

            /// One startup task that ran: its name, whether it was posted to the main thread, and its times.
            struct TaskSlice {
                var name: String
                var onMain: Bool
                var startNanos: UInt64
                var durationNanos: UInt64
            }

            /// The ring's events and each of `tasks` that ran 1 ms or more.
            func events(adding tasks: [TaskSlice]) -> [Event] {
                events + tasks.compactMap { task -> Event? in
                    guard task.durationNanos >= SlowLaunchRing.sliceThresholdNanos else { return nil }
                    let start = task.startNanos > processStartNanos ? task.startNanos - processStartNanos : 0
                    return Event(kind: task.onMain ? .mainTask : .laneTask, name: task.name, startMicros: start / 1_000,
                                 durationMicros: task.durationNanos / 1_000)
                }
            }

            /// The events, oldest first.
            public var events: [Event] {
                records.map { record -> Event in
                    let start = record.start > processStartNanos ? record.start - processStartNanos : 0
                    let duration = record.end > record.start ? record.end - record.start : 0
                    let (kind, name): (Event.Kind, String) = switch record.event {
                    case let .mark(mark): (.mark, mark)
                    case let .task(task): (mainThread == record.thread ? .mainTask : .laneTask, task.description)
                    case .mainTurn: (.mainTurn, "main.turn")
                    case let .laneJob(lane, priority): (.laneJob, "\(lane.description).\(priority.description)")
                    }
                    return Event(kind: kind, name: name, startMicros: start / 1_000, durationMicros: kind == .mark ? 0 : duration / 1_000)
                }
            }
        }

        /// The ring of this launch when hang reports are on (`optedIn`: this Mac's consent is recorded), else nil after
        /// reading nothing: no ring is allocated and `processStartNanos` is not read.
        public static func forReports(optedIn: Bool, processStartNanos: @autoclosure () -> UInt64) -> SlowLaunchRing? {
            optedIn ? SlowLaunchRing(processStartNanos: processStartNanos()) : nil
        }

        /// Made on the main thread (in `main()`), so a startup task recorded on that thread is a main task.
        ///
        /// - Parameters:
        ///   - processStartNanos: `CLOCK_UPTIME_RAW` nanoseconds at process start.
        ///   - bytes: The ring's size (``defaultBytes``); it holds `bytes / stride` records, at least one.
        ///   - now: `CLOCK_UPTIME_RAW` nanoseconds now; tests inject their own.
        public convenience init(processStartNanos: UInt64, bytes: Int = SlowLaunchRing.defaultBytes,
                                now: (@Sendable () -> UInt64)? = nil) {
            self.init(processStartNanos: processStartNanos, bytes: bytes,
                      mainThread: pthread_main_np() != 0 ? StartupTrace.threadID() : nil, now: now)
        }

        /// As ``init(processStartNanos:bytes:now:)``, with the main thread's id given (nil: no thread is the main one).
        init(processStartNanos: UInt64, bytes: Int, mainThread: UInt64?, now: (@Sendable () -> UInt64)?) {
            self.processStartNanos = processStartNanos
            self.mainThread = mainThread
            self.now = now ?? { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
            let stride = MemoryLayout<StartupTraceRecord>.stride
            let capacity = max(1, bytes / stride)
            self.capacity = capacity
            ringBytes = capacity * stride
            var records: [StartupTraceRecord] = []
            records.reserveCapacity(capacity)
            state = Mutex(State(records: records))
        }

        // MARK: recording

        /// A launch mark at `nanos` (`CLOCK_UPTIME_RAW`; default now), on the calling thread.
        public func mark(_ name: String, at nanos: UInt64? = nil) {
            guard recording.load(ordering: .relaxed) else { return }
            let time = nanos ?? now()
            record(StartupTraceRecord(event: .mark(name), start: time, end: time, thread: StartupTrace.threadID()))
        }

        /// A startup task that ran from `start` to `end` (default now) on the calling thread; under 1 ms, nothing.
        public func task(_ name: StaticString, start: UInt64, end: UInt64? = nil) {
            guard recording.load(ordering: .relaxed) else { return }
            slice(.task(name), start: start, end: end ?? now())
        }

        /// The ring's clock now (`CLOCK_UPTIME_RAW` nanoseconds): a startup task's start for ``task(_:start:end:)``.
        public var uptimeNanos: UInt64 { now() }

        /// A main-thread run-loop turn from `start` to `end` (the watchdog's main-turn sink, on the main thread).
        public func mainTurn(start: UInt64, end: UInt64) {
            guard recording.load(ordering: .relaxed) else { return }
            slice(.mainTurn, start: start, end: end)
        }

        /// ``BackgroundWork``'s `onRan`: each item over 1 ms, by lane and priority, recorded on its lane thread.
        public var laneJobSink: @Sendable (BlockingLane, WorkPriority, UInt64, UInt64) -> Void {
            { [self] lane, priority, start, end in
                guard recording.load(ordering: .relaxed) else { return }
                slice(.laneJob(lane, priority), start: start, end: end)
            }
        }

        private func slice(_ event: StartupTraceRecord.Event, start: UInt64, end: UInt64) {
            guard end > start, end - start >= Self.sliceThresholdNanos else { return }
            record(StartupTraceRecord(event: event, start: start, end: end, thread: StartupTrace.threadID()))
        }

        private func record(_ record: StartupTraceRecord) {
            state.withLock { state in
                guard !state.freed else { return }
                if state.records.count < capacity {
                    state.records.append(record)
                    return
                }
                // Full: capacity records, and next stays in 0..<capacity.
                state.records[state.next] = record
                state.next = (state.next + 1) % capacity
                state.overwritten += 1
            }
        }

        // MARK: completion

        /// Frees the ring at `startup_complete` and stops recording; the freed hooks run before it returns. Returns the
        /// launch's records when `keeping` (the launch missed its budget) and the ring was not freed before, else nil.
        @discardableResult
        public func finish(keeping: Bool) -> Launch? {
            let taken = state.withLock { state -> (records: [StartupTraceRecord], next: Int, overwritten: Int,
                                                   hooks: [@Sendable () -> Void])? in
                guard !state.freed else { return nil }
                state.freed = true
                recording.store(false, ordering: .relaxed)
                var records: [StartupTraceRecord] = []
                swap(&records, &state.records)
                let hooks = state.freedHooks
                state.freedHooks = []
                return (records, state.next, state.overwritten, hooks)
            }
            guard let taken else { return nil }
            for hook in taken.hooks { hook() }
            guard keeping else { return nil }
            let oldestFirst = Array(taken.records[taken.next...] + taken.records[..<taken.next])
            return Launch(records: oldestFirst, processStartNanos: processStartNanos, mainThread: mainThread,
                          overwritten: taken.overwritten)
        }

        /// Runs `action` once, after the ring is freed (at once when it already was): the producers' hooks come off
        /// then (the watchdog's main-turn sink, ``BackgroundWork/stopReportingRuns()``), so a freed ring costs the
        /// main thread and the lanes nothing. `action` must return at once.
        public func whenFreed(_ action: @escaping @Sendable () -> Void) {
            let freed = state.withLock { state -> Bool in
                if !state.freed { state.freedHooks.append(action) }
                return state.freed
            }
            if freed { action() }
        }

        /// The bytes the ring holds now: ``ringBytes`` while recording, 0 once freed.
        public var heldBytes: Int {
            state.withLock { $0.freed ? 0 : $0.records.capacity * MemoryLayout<StartupTraceRecord>.stride }
        }

        /// Records the ring overwrote so far.
        public var overwritten: Int { state.withLock { $0.overwritten } }
    }
}
