#if DEBUG || CMUX_BENCH_HOOKS
import Darwin
import Dispatch

/// The recording side of the launch's main-job census (p08-startup task 080, queue Q11; CmuxNextLaunch's
/// `MainJobCensus` reads it): every main-actor job the Swift runtime enqueues, and every main-thread post the app
/// makes (CmuxNextWakeups' `MainDelivery` hop from another thread, a ``MainRunLoopBlock``, a `DemandTimer` deadline's
/// fire), with its enqueuer's return addresses, its priority and its run time, in one preallocated buffer.
///
/// `swift_task_enqueueMainExecutor_hook` hands each main-actor job to ``enqueue(_:original:)``. A slot is claimed
/// with one atomic add; the enqueuing thread writes the slot's time, priority and return addresses
/// (`backtrace_async`, a frame-pointer walk that follows a running task's async frames: no lock, no allocation),
/// then puts the job on the main dispatch queue (the queue the runtime's own main executor uses) at the job's QoS,
/// so jobs keep their order. On the main thread the job runs between two clock reads (``run(slot:_:)``). The app's
/// own posts claim their slot where they post (``recordEnqueue(_:priority:label:)``) and run the same way. A timer
/// has no useful post stack at its fire, so it is named by its owner (the slot's label), and a main-actor job its
/// fire enqueues on the main thread takes that label too. Chrome times every UI-thread task the same way, from its
/// post site (base/task/common/task_annotator.cc, `TaskAnnotator::RunTask` with the task's `PostedFrom` location).
///
/// Bounded: the first ``capacity`` jobs are kept; later ones, and every job after ``freeze()``, take the runtime's
/// own path and count as dropped. Debug and bench-hooks builds only, and only in a launch that armed the census.
///
/// Continuous (``init(capacity:continuous:clock:)`` with `continuous`, the census's input window,
/// sequence-manager-DESIGN.md 2.7): slots are reused. A claim takes slot `claim % capacity` only when that slot is free
/// (an atomic exchange; a busy one sends the job the runtime's way and counts it in ``busyDrops``), and the main
/// thread frees it after the job ran, once its record is copied into a main-thread ring of the ``recentLimit`` newest
/// runs. ``noteInputDispatch(eventNanos:dispatchNanos:)`` copies the runs that overlap the wait between an event's
/// arrival and its dispatch into the input window, which ``readInputWindow()`` returns.
///
/// This file is the one owner of `swift_task_enqueueMainExecutor_hook` (guardrail `executor-hook`): the hook only
/// records and forwards each job to the main queue in its order; nothing in the app reorders main-actor jobs.
///
/// Memory safety: each buffer is one allocation of `capacity` initialized slots (frames: `capacity * depth`) made
/// by init and never freed, because the hook may call in for the life of the process. The input window's storage (main thread
/// only) is one more such allocation. A slot index comes only from
/// ``recordEnqueue(_:priority:label:)``, which returns indices under `capacity`, or is checked against it.
///
/// ```swift
/// let ring = MainJobRing(capacity: 8_192)
/// _ = ring.install()        // in `main`, before any other thread starts
/// // ... launch ...
/// ring.freeze()             // startup complete
/// let (jobs, pending, dropped) = ring.read()
/// ```
@safe
public final class MainJobRing: @unchecked Sendable { // crash-allow: a slot's enqueue fields are written only by the thread that claimed it, before that thread queues the job on the main dispatch queue or run loop (which publishes them to the main thread); a continuous ring reuses a slot only after the main thread copied its last job and freed it with a release store that the next claim's exchange acquires; a label is written only on the main thread; the run fields, the running label and the tally are read and written on the main thread only
    typealias Original = @convention(thin) (UnownedJob) -> Void
    typealias Hook = @convention(thin) (UnownedJob, Original) -> Void

    /// What enqueued a job.
    public enum Kind: UInt8, Sendable {
        /// A main-actor job (`Task { @MainActor }`, an `await` that resumes on the main actor, a continuation).
        case mainActor = 0
        /// A `MainDelivery` hop from another thread (a main-queue block).
        case mainDelivery = 1
        /// A ``MainRunLoopBlock`` post (a run-loop block).
        case runLoopBlock = 2
        /// A `DemandTimer` deadline's fire on the main thread's wake-up queue; its label is the timer's owner.
        case timer = 3
    }

    /// What ``install()`` found.
    public enum HookState: String, Sendable {
        /// Every main-actor job goes through the ring.
        case installed
        /// This Swift runtime exports no `swift_task_enqueueMainExecutor_hook`.
        case missing
        /// Another hook (or another ring) holds it: this ring sees no main-actor job.
        case busy
    }

    /// The jobs that ran since the last ``takeTally()`` (main thread only).
    public struct Tally: Sendable, Equatable {
        public var jobs = 0
        public var nanos: UInt64 = 0
        /// The slot of the longest job, nil with no job.
        public var longestSlot: Int?
        public var longestNanos: UInt64 = 0

        public init() {}
    }

    /// One job that ran.
    public struct Job: Sendable, Equatable {
        public var slot: Int
        public var kind: Kind
        /// `CLOCK_UPTIME_RAW` nanoseconds.
        public var enqueuedNanos: UInt64
        /// `CLOCK_UPTIME_RAW` nanoseconds: when the job started to run.
        public var runStartNanos: UInt64
        public var runNanos: UInt64
        /// The QoS class raw value (`JobPriority` / `qos_class_t`), 0 unspecified.
        public var priority: UInt8
        /// The enqueuer's name when its stack cannot give one: a timer's owner, also on the main-actor jobs its fire
        /// enqueued on the main thread. Nil for the rest.
        public var label: String?
        /// Return addresses, the innermost first (the ring's own frames included).
        public var frames: [UInt]

        public init(slot: Int, kind: Kind, enqueuedNanos: UInt64, runStartNanos: UInt64, runNanos: UInt64, priority: UInt8,
                    label: String? = nil, frames: [UInt]) {
            self.slot = slot
            self.kind = kind
            self.enqueuedNanos = enqueuedNanos
            self.runStartNanos = runStartNanos
            self.runNanos = runNanos
            self.priority = priority
            self.label = label
            self.frames = frames
        }
    }

    /// The return addresses kept per job: the ring's and the runtime's enqueue frames, then the enqueuer's (as
    /// CmuxNextWakeups' `HopRecord.depth`).
    public static let depth = 16

    /// The image whose `swift_task_enqueueMainExecutor` calls the hook: in a main-actor job's stack, the frames
    /// before its first one are the ring's own.
    public static let concurrencyRuntimeImage = "libswift_Concurrency.dylib"
    /// The images a main job's enqueue passes through between the ring and the code that enqueued it, never its
    /// site: the Swift concurrency runtime, the Swift core library, libdispatch and its Swift overlay, and the thread
    /// start below a worker's stack. CmuxNextWakeups' `HopFrameResolver` reads the same table.
    public static let enqueueRuntimeImages: Set<String> = [concurrencyRuntimeImage, "libswiftCore.dylib", "libdispatch.dylib",
                                                           "libswiftDispatch.dylib", "libsystem_pthread.dylib"]
    /// The mangled prefixes of the `Task` and `MainActor` members the compiler emits into the caller's image
    /// (`Task.init`, `MainActor.run`): not inlined in a DEBUG build, they would name every `Task { }` of a module as
    /// one site. `HopFrameResolver` reads the same table.
    public static let enqueueRuntimeSymbolPrefixes = ["$sScT", "$sScM"]

    public let capacity: Int
    /// Slots are reused (the input window); false: the first ``capacity`` jobs are kept.
    public let continuous: Bool
    private let clock: @Sendable () -> UInt64
    private let claims = Atomic<Int>(0)
    private let frozen = Atomic<Bool>(false)
    /// Continuous only: 1 while a slot's job has not run (written by the claiming thread, freed by the main thread).
    private let busy: UnsafeMutablePointer<UInt64>
    private let busyDropCount = Atomic<Int>(0)
    /// Continuous only, main thread only: the newest runs and the input window (MainJobRing+InputWindow.swift).
    let window: UnsafeMutablePointer<InputWindowStore>
    // Written by the claiming thread before it queues the job.
    private let kinds: UnsafeMutablePointer<UInt8>
    private let enqueued: UnsafeMutablePointer<UInt64>
    private let priorities: UnsafeMutablePointer<UInt8>
    private let frameCounts: UnsafeMutablePointer<Int32>
    private let frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    // Main thread only.
    private let labels: UnsafeMutablePointer<String?>
    private let runStarts: UnsafeMutablePointer<UInt64>
    private let runNanos: UnsafeMutablePointer<UInt64>
    private let ran: UnsafeMutablePointer<Bool>
    private let tally: UnsafeMutablePointer<Tally>
    /// The label of the labeled job running now, which the main-actor jobs it enqueues take.
    private let runningLabel: UnsafeMutablePointer<String?>

    /// A ring on the `CLOCK_UPTIME_RAW` clock.
    ///
    /// - Parameters:
    ///   - capacity: The jobs kept (one slot each, about 170 bytes).
    ///   - continuous: Reuse slots and keep the input window (the census's input mode).
    public convenience init(capacity: Int, continuous: Bool = false) {
        // Darwin is an internal import, so the clock cannot be a public default argument value.
        self.init(capacity: capacity, continuous: continuous) { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    }

    /// - Parameters:
    ///   - capacity: The jobs kept (one slot each, about 170 bytes); continuous: the jobs queued and not run yet.
    ///   - continuous: Reuse slots and keep the input window (the census's input mode).
    ///   - clock: `CLOCK_UPTIME_RAW` nanoseconds (tests pass their own).
    public init(capacity: Int, continuous: Bool = false, clock: @escaping @Sendable () -> UInt64) {
        let count = max(capacity, 1)
        self.capacity = count
        self.continuous = continuous
        self.clock = clock
        // SAFETY: fresh allocations, each initialized here at its full size and never freed (the type's note).
        unsafe kinds = .allocate(capacity: count)
        unsafe kinds.initialize(repeating: 0, count: count)
        unsafe enqueued = .allocate(capacity: count)
        unsafe enqueued.initialize(repeating: 0, count: count)
        unsafe priorities = .allocate(capacity: count)
        unsafe priorities.initialize(repeating: 0, count: count)
        unsafe frameCounts = .allocate(capacity: count)
        unsafe frameCounts.initialize(repeating: 0, count: count)
        unsafe frames = .allocate(capacity: count * Self.depth)
        unsafe frames.initialize(repeating: nil, count: count * Self.depth)
        unsafe labels = .allocate(capacity: count)
        unsafe labels.initialize(repeating: nil, count: count)
        unsafe runStarts = .allocate(capacity: count)
        unsafe runStarts.initialize(repeating: 0, count: count)
        unsafe runNanos = .allocate(capacity: count)
        unsafe runNanos.initialize(repeating: 0, count: count)
        unsafe ran = .allocate(capacity: count)
        unsafe ran.initialize(repeating: false, count: count)
        unsafe tally = .allocate(capacity: 1)
        unsafe tally.initialize(to: Tally())
        unsafe runningLabel = .allocate(capacity: 1)
        unsafe runningLabel.initialize(to: nil)
        unsafe busy = .allocate(capacity: continuous ? count : 1)
        unsafe busy.initialize(repeating: 0, count: continuous ? count : 1)
        unsafe window = .allocate(capacity: 1)
        unsafe window.initialize(to: InputWindowStore(sized: continuous))
    }

    /// `CLOCK_UPTIME_RAW` nanoseconds now, on the ring's clock.
    public var now: UInt64 { clock() }

    // MARK: Recording

    /// Claims a slot and records an enqueue now, from any thread: its kind, `priority` (a QoS class raw value) and
    /// the calling thread's return addresses. `label` names the enqueuer (main thread only); with none, a main-actor
    /// job enqueued on the main thread while a labeled job runs takes that job's label (the `Task` a `DemandTimer`
    /// fire starts has only `DemandTimer` on its stack). Nil when the ring is full or frozen (the drop is counted).
    @inline(never)
    public func recordEnqueue(_ kind: Kind, priority: UInt8, label: String? = nil) -> Int? {
        guard !frozen.load(ordering: .relaxed) else { return nil }
        let claim = claims.add(1, ordering: .relaxed).oldValue
        guard let slot = claimSlot(claim) else { return nil }
        // SAFETY: slot < capacity (the claim above), and only this thread writes these fields of the slot.
        unsafe kinds[slot] = kind.rawValue
        unsafe enqueued[slot] = clock()
        unsafe priorities[slot] = priority
        if pthread_main_np() != 0 {
            // SAFETY: slot < capacity; the labels and the running label are main-thread only, and this is the main thread.
            unsafe labels[slot] = label ?? (kind == .mainActor ? runningLabel.pointee : nil)
        }
        // A hop that an `await` enqueues (`swift_task_switch`, reached by a tail call) leaves no frame of the
        // awaiting function on this thread's stack: `backtrace_async` follows the task's async frames to it.
        var task: UInt32 = 0
        // SAFETY: backtrace_async writes at most `depth` addresses, into the slot's own `depth` entries of `frames`.
        let count = unsafe backtrace_async(frames + slot * Self.depth, Self.depth, &task)
        unsafe frameCounts[slot] = Int32(truncatingIfNeeded: min(count, Self.depth))
        return slot
    }

    /// Main thread: runs `work`, the job of `slot` (from ``recordEnqueue(_:priority:label:)``), between two clock
    /// reads; a main-actor job `work` enqueues takes the slot's label.
    public func run(slot: Int, _ work: () -> Void) {
        guard slot >= 0, slot < capacity else { return work() }
        // SAFETY: slot < capacity (checked above); the labels and the running label are main-thread only.
        let outer = unsafe runningLabel.pointee
        if let label = unsafe labels[slot] { unsafe runningLabel.pointee = label }
        let start = clock()
        work()
        let nanos = clock() &- start
        unsafe runningLabel.pointee = outer
        recordRun(slot: slot, startNanos: start, nanos: nanos)
        if continuous { keepRun(slot: slot, startNanos: start, nanos: nanos) }
    }

    /// The slot of claim number `claim`, or nil (full, or the slot's last job has not run: continuous).
    private func claimSlot(_ claim: Int) -> Int? {
        guard continuous else { return claim < capacity ? claim : nil }
        let slot = claim % capacity
        // SAFETY: slot < capacity, and `busy` holds `capacity` aligned words in continuous mode (init). Acquiring: the
        // main thread's copy of the slot's last job (keepRun) is done before this thread writes the slot again.
        guard unsafe AtomicPointerSlot(busy + slot).exchange(1, ordering: .acquiringAndReleasing) == 0 else {
            busyDropCount.add(1, ordering: .relaxed)
            return nil
        }
        return slot
    }

    /// Main thread, continuous: copies the slot's run into the newest runs, then frees the slot for a later claim.
    private func keepRun(slot: Int, startNanos: UInt64, nanos: UInt64) {
        let base = slot * Self.depth
        let count = unsafe Int(max(0, min(frameCounts[slot], Int32(Self.depth))))
        // SAFETY: slot < capacity (run checked it); the slot's enqueue fields were published to the main thread by the
        // queue that ran the job, and stay unchanged until the release store below frees the slot.
        let run = unsafe InputWindowStore.Run(kind: kinds[slot], priority: priorities[slot], frameCount: count,
                                              enqueuedNanos: enqueued[slot], startNanos: startNanos, nanos: nanos, label: labels[slot])
        unsafe window.pointee.keep(run, frames: frames + base)
        unsafe labels[slot] = nil
        // SAFETY: as in claimSlot. Releasing: the copy above happens before the next claim of this slot.
        unsafe AtomicPointerSlot(busy + slot).store(0, ordering: .releasing)
    }

    /// Continuous: jobs that took the runtime's way because their slot's last job had not run yet.
    public var busyDrops: Int { busyDropCount.load(ordering: .relaxed) }

    /// Main thread: the job of `slot` started at `startNanos` and ran for `nanos`; it counts in the tally.
    public func recordRun(slot: Int, startNanos: UInt64, nanos: UInt64) {
        guard slot >= 0, slot < capacity else { return }
        // SAFETY: slot is under capacity (checked above); the run fields and the tally are main-thread only.
        unsafe runStarts[slot] = startNanos
        unsafe runNanos[slot] = nanos
        unsafe ran[slot] = true
        unsafe tally.pointee.jobs += 1
        unsafe tally.pointee.nanos &+= nanos
        if unsafe tally.pointee.longestSlot == nil || nanos > tally.pointee.longestNanos {
            unsafe tally.pointee.longestNanos = nanos
            unsafe tally.pointee.longestSlot = slot
        }
    }

    /// Main thread: the tally since the last call; the next one starts empty.
    public func takeTally() -> Tally {
        // SAFETY: the one tally init made; main-thread only.
        let taken = unsafe tally.pointee
        unsafe tally.pointee = Tally()
        return taken
    }

    /// No later job is recorded (startup completed).
    public func freeze() { frozen.store(true, ordering: .releasing) }

    /// `work`, timed into the ring when it is recorded: `MainDelivery`'s off-main hop. Unchanged when the ring is
    /// full or frozen.
    public func timed(_ work: @escaping @MainActor @Sendable () -> Void) -> @MainActor @Sendable () -> Void {
        guard let slot = recordEnqueue(.mainDelivery, priority: Self.currentPriority) else { return work }
        return { [self] in run(slot: slot) { work() } }
    }

    /// The calling thread's QoS class raw value.
    public static var currentPriority: UInt8 { UInt8(truncatingIfNeeded: qos_class_self().rawValue) }

    /// The hook's work for one main-actor job: recorded, then run on the main dispatch queue at its QoS between two
    /// clock reads; or, when the ring is full or frozen, given to the runtime's own enqueue.
    func enqueue(_ job: UnownedJob, original: Original) {
        let priority = job.priority.rawValue
        guard let slot = recordEnqueue(.mainActor, priority: priority) else { return original(job) }
        let qos = DispatchQoS.QoSClass(rawValue: qos_class_t(rawValue: UInt32(priority))) ?? .unspecified
        // main-async-allow: the Swift runtime's main executor puts every main-actor job on this queue at its QoS; the ring keeps the job's place and QoS there
        DispatchQueue.main.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0)) { [self] in
            run(slot: slot) { job.runSynchronously(on: MainActor.sharedUnownedExecutor) }
        }
    }

    // MARK: Reading

    /// Main thread: the jobs that ran, in claim order; the jobs claimed and not run yet; the jobs dropped. Empty for a
    /// continuous ring (its slots are reused: ``readInputWindow()``).
    public func read() -> (jobs: [Job], pending: Int, dropped: Int) {
        guard !continuous else { return ([], 0, busyDrops) }
        let claimed = claims.load(ordering: .acquiring)
        let kept = min(claimed, capacity)
        var jobs: [Job] = []
        jobs.reserveCapacity(kept)
        for slot in 0 ..< kept {
            // SAFETY: slot < capacity. `ran` is main-thread only, and a slot that ran had its enqueue fields published
            // to the main thread by the main dispatch queue (or written on it).
            guard unsafe ran[slot] else { continue }
            let count = unsafe Int(max(0, min(frameCounts[slot], Int32(Self.depth))))
            let base = slot * Self.depth
            // SAFETY: base + count is inside the slot's own `depth` entries of `frames`.
            let addresses = unsafe (0 ..< count).map { unsafe UInt(bitPattern: frames[base + $0]) }
            unsafe jobs.append(Job(slot: slot, kind: Kind(rawValue: kinds[slot]) ?? .mainActor, enqueuedNanos: enqueued[slot],
                                   runStartNanos: runStarts[slot], runNanos: runNanos[slot], priority: priorities[slot],
                                   label: labels[slot], frames: addresses))
        }
        return (jobs, kept - jobs.count, max(0, claimed - capacity))
    }

    // MARK: The runtime hook

    /// The installed ring's address (`Unmanaged`, retained for the process), 0 before an install. The runtime's hook
    /// is a thin function with no context, and `MainDelivery`, ``MainRunLoopBlock`` and `DemandTimer`'s fire have none
    /// to pass: this word is how they find the ring the composition root made.
    private static let installedBits = Atomic<UInt>(0)

    /// The ring the hook records into, nil when no launch armed the census.
    public static func installed() -> MainJobRing? {
        let bits = installedBits.load(ordering: .acquiring)
        // SAFETY: a nonzero word is a ring install() retained and never released, so the address stays valid.
        guard bits != 0, let raw = unsafe UnsafeRawPointer(bitPattern: bits) else { return nil }
        return unsafe Unmanaged<MainJobRing>.fromOpaque(raw).takeUnretainedValue()
    }

    /// The runtime's hook variable, nil when this Swift runtime exports none.
    private static func hookVariable() -> UnsafeMutablePointer<Hook?>? {
        // SAFETY: RTLD_DEFAULT (-2) searches every loaded image; the symbol, when found, is libswift_Concurrency's
        // exported `swift_task_enqueueMainExecutor_hook`, a pointer-sized variable of the Swift-convention function
        // type `Hook?` (swift/Runtime/Concurrency.h); it is only read and written as that type.
        guard let symbol = unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_task_enqueueMainExecutor_hook") else { return nil }
        return unsafe symbol.assumingMemoryBound(to: Hook?.self)
    }

    /// Sends every main-actor job and main-thread post of the process through this ring. Once per process, in
    /// `main` while it has one thread: a second ring, or a hook someone else set, finds it ``HookState/busy``.
    public func install() -> HookState {
        guard let variable = Self.hookVariable() else { return .missing }
        guard unsafe variable.pointee == nil else { return .busy }
        // SAFETY: one retain the process keeps (installed() reads the address back); released at once when the word
        // is taken, before any hook saw it.
        let retained = unsafe Unmanaged.passRetained(self)
        let bits = unsafe UInt(bitPattern: retained.toOpaque())
        guard Self.installedBits.compareExchange(expected: 0, desired: bits, ordering: .acquiringAndReleasing).exchanged else {
            unsafe retained.release()
            return .busy
        }
        // SAFETY: the runtime's hook variable (hookVariable), written in `main` while no other thread enqueues.
        unsafe variable.pointee = { job, original in
            if let ring = MainJobRing.installed() { ring.enqueue(job, original: original) } else { original(job) }
        }
        return .installed
    }
}
#endif
