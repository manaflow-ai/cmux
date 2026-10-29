#if DEBUG || CMUX_BENCH_HOOKS
/// The input window of a continuous ``MainJobRing`` (sequence-manager-DESIGN.md 2.7 and S6): the main jobs that ran
/// between an input event's arrival and its dispatch, each with its enqueuer's stack, so the census can name the
/// unposted main jobs (``MainJobRing/Kind/mainActor``) that held input back, by enqueue site.
///
/// The main thread keeps the ``recentLimit`` newest runs (in the order they ended); at each event's dispatch
/// (``MainJobRing/noteInputDispatch(eventNanos:dispatchNanos:)``) it copies the runs that overlap
/// `[arrival, dispatch)` into the window. Everything is preallocated: past ``jobLimit`` copied jobs or ``eventLimit``
/// events, the rest are counted as dropped. Chrome's input scheduler attributes queueing time the same way, to the
/// tasks that ran ahead of the input (third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc).
///
/// ```swift
/// let ring = MainJobRing(capacity: 16_384, continuous: true)
/// ring.noteInputDispatch(eventNanos: arrival, dispatchNanos: ring.now)   // CmuxApplication.route, each key or click
/// let window = ring.readInputWindow()                                    // debug.main_jobs.input
/// ```
extension MainJobRing {
    /// One input event the window saw dispatched.
    public struct InputEvent: Sendable, Equatable {
        /// `CLOCK_UPTIME_RAW` nanoseconds: the event's own time (a key's HID time; `debug.key`: when the client sent it).
        public var arrivalNanos: UInt64
        /// `CLOCK_UPTIME_RAW` nanoseconds: when its dispatch began.
        public var dispatchNanos: UInt64
    }

    /// One main job that ran while an event waited for its dispatch.
    public struct InputJob: Sendable, Equatable {
        /// The index of the event in ``InputWindow/events``.
        public var event: Int
        /// The job (its `slot` is the order it was copied in).
        public var job: Job
        /// The part of its run inside `[arrival, dispatch)`.
        public var inWindowNanos: UInt64
    }

    /// The window as ``readInputWindow()`` copies it.
    public struct InputWindow: Sendable, Equatable {
        public var events: [InputEvent]
        public var jobs: [InputJob]
        /// Events past ``eventLimit``.
        public var droppedEvents: Int
        /// Jobs past ``jobLimit``.
        public var droppedJobs: Int
        /// Jobs the ring never saw: their slot's last job had not run yet (``busyDrops``).
        public var busyDrops: Int
    }

    /// The newest runs kept for the next dispatch.
    public static let recentLimit = InputWindowStore.recentLimit
    /// The jobs the window holds until a reset.
    public static let jobLimit = InputWindowStore.jobLimit
    /// The events the window holds until a reset.
    public static let eventLimit = InputWindowStore.eventLimit

    /// Main thread: an input event that arrived at `eventNanos` begins its dispatch at `dispatchNanos`; the runs that
    /// overlap that wait go into the window. Nothing for a ring that is not continuous.
    public func noteInputDispatch(eventNanos: UInt64, dispatchNanos: UInt64) {
        guard continuous else { return }
        // SAFETY: the window is one main-thread-only value made by init and never freed (the type's note).
        unsafe window.pointee.noteDispatch(eventNanos: eventNanos, dispatchNanos: dispatchNanos)
    }

    /// Main thread: what the window holds now.
    public func readInputWindow() -> InputWindow {
        // SAFETY: as in noteInputDispatch.
        unsafe window.pointee.read(busyDrops: busyDrops)
    }

    /// Main thread: empties the window (the newest runs stay).
    public func resetInputWindow() {
        // SAFETY: as in noteInputDispatch.
        unsafe window.pointee.reset()
    }
}

/// The main-thread storage of the input window: preallocated arrays, written with no allocation after init. Empty
/// (no storage) for a ring that is not continuous.
struct InputWindowStore {
    static let recentLimit = 16_384
    static let jobLimit = 65_536
    static let eventLimit = 16_384

    /// One run as it is kept: its frames are in the matching `depth` entries of a frame array.
    struct Run {
        var kind: UInt8 = 0
        var priority: UInt8 = 0
        var frameCount = 0
        var enqueuedNanos: UInt64 = 0
        var startNanos: UInt64 = 0
        var nanos: UInt64 = 0
        var label: String?
    }

    private let depth = MainJobRing.depth
    private var recent: [Run]
    private var recentFrames: [UInt]
    /// The next index of `recent` to write, and how many are written (at most recentLimit).
    private var recentNext = 0, recentCount = 0
    private var events: [MainJobRing.InputEvent] = []
    private var jobs: [(event: Int, run: Run, inWindow: UInt64)] = []
    private var jobFrames: [UInt]
    private var droppedEvents = 0, droppedJobs = 0

    init(sized: Bool) {
        let recentSize = sized ? Self.recentLimit : 0, jobSize = sized ? Self.jobLimit : 0
        recent = Array(repeating: Run(), count: max(0, recentSize))
        recentFrames = Array(repeating: 0, count: max(0, recentSize * MainJobRing.depth))
        jobFrames = Array(repeating: 0, count: max(0, jobSize * MainJobRing.depth))
        events.reserveCapacity(sized ? Self.eventLimit : 0)
        jobs.reserveCapacity(jobSize)
    }

    /// Keeps `run` as the newest, over the oldest when full; its `frameCount` return addresses are read from `frames`.
    @unsafe
    mutating func keep(_ run: Run, frames: UnsafePointer<UnsafeMutableRawPointer?>) {
        guard !recent.isEmpty else { return }
        let index = recentNext
        recent[index] = run
        for offset in 0 ..< run.frameCount { recentFrames[index * depth + offset] = unsafe UInt(bitPattern: frames[offset]) }
        recentNext = (index + 1) % recent.count
        recentCount = min(recentCount + 1, recent.count)
    }

    /// Copies the kept runs that overlap `[eventNanos, dispatchNanos)`, newest first. The runs are in the order they
    /// ended (a job's nested run loop ends the jobs it ran first), so the walk stops at the first run that ended
    /// before the event arrived.
    mutating func noteDispatch(eventNanos: UInt64, dispatchNanos: UInt64) {
        guard !recent.isEmpty else { return }
        guard events.count < Self.eventLimit else { return droppedEvents += 1 }
        let event = events.count
        events.append(MainJobRing.InputEvent(arrivalNanos: eventNanos, dispatchNanos: dispatchNanos))
        guard dispatchNanos > eventNanos else { return }
        var index = recentNext
        for _ in 0 ..< recentCount {
            index = (index + recent.count - 1) % recent.count
            let run = recent[index]
            let end = run.startNanos &+ run.nanos
            if end <= eventNanos { break }
            let from = max(run.startNanos, eventNanos), to = min(end, dispatchNanos)
            guard to > from else { continue }
            guard jobs.count < Self.jobLimit else {
                droppedJobs += 1
                continue
            }
            let copied = jobs.count
            for offset in 0 ..< run.frameCount { jobFrames[copied * depth + offset] = recentFrames[index * depth + offset] }
            jobs.append((event, run, to - from))
        }
    }

    func read(busyDrops: Int) -> MainJobRing.InputWindow {
        let copied = jobs.enumerated().map { copied, entry in
            let frames = Array(jobFrames[(copied * depth) ..< (copied * depth + entry.run.frameCount)])
            let job = MainJobRing.Job(slot: copied, kind: MainJobRing.Kind(rawValue: entry.run.kind) ?? .mainActor,
                                      enqueuedNanos: entry.run.enqueuedNanos, runStartNanos: entry.run.startNanos,
                                      runNanos: entry.run.nanos, priority: entry.run.priority, label: entry.run.label, frames: frames)
            return MainJobRing.InputJob(event: entry.event, job: job, inWindowNanos: entry.inWindow)
        }
        return MainJobRing.InputWindow(events: events, jobs: copied, droppedEvents: droppedEvents, droppedJobs: droppedJobs,
                                       busyDrops: busyDrops)
    }

    mutating func reset() {
        events.removeAll(keepingCapacity: true)
        jobs.removeAll(keepingCapacity: true)
        droppedEvents = 0
        droppedJobs = 0
    }
}
#endif
