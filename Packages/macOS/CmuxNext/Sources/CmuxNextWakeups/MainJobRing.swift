#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
import Darwin
import Dispatch

/// The recording side of the launch's main-job census (p08-startup task 080, queue Q11; CmuxNextLaunch's
/// `MainJobCensus` reads it): every main-actor job the Swift runtime enqueues, and every ``MainDelivery`` hop from
/// another thread, with its enqueuer's return addresses, its priority and its run time, in one preallocated buffer.
///
/// `swift_task_enqueueMainExecutor_hook` hands each main-actor job to ``enqueue(_:original:)``. A slot is claimed
/// with one atomic add; the enqueuing thread writes the slot's time, priority and return addresses (`backtrace`, a
/// frame-pointer walk: no lock, no allocation), then puts the job on the main dispatch queue (the queue the
/// runtime's own main executor uses) at the job's QoS, so jobs keep their order. On the main thread the job runs
/// between two clock reads. Chrome times every UI-thread task the same way, from its post site
/// (base/task/common/task_annotator.cc, `TaskAnnotator::RunTask` with the task's `PostedFrom` location).
///
/// Bounded: the first ``capacity`` jobs are kept; later ones, and every job after ``freeze()``, take the runtime's
/// own path and count as dropped. Debug and bench-hooks builds only, and only in a launch that armed the census.
///
/// Memory safety: each buffer is one allocation of `capacity` initialized slots (frames: `capacity * depth`) made
/// by init and never freed, because the hook may call in for the life of the process. A slot index comes only from
/// ``recordEnqueue(_:priority:)``, which returns indices under `capacity`, or is checked against it.
///
/// ```swift
/// let ring = MainJobRing(capacity: 8_192)
/// _ = ring.install()        // in `main`, before any other thread starts
/// // ... launch ...
/// ring.freeze()             // startup complete
/// let (jobs, pending, dropped) = ring.read()
/// ```
@safe
public final class MainJobRing: @unchecked Sendable { // crash-allow: a slot's enqueue fields are written once, by the thread that claimed it, before that thread queues the job on the main dispatch queue (which publishes them to the main thread); the run fields and the tally are read and written on the main thread only
    typealias Original = @convention(thin) (UnownedJob) -> Void
    typealias Hook = @convention(thin) (UnownedJob, Original) -> Void

    /// What enqueued a job.
    public enum Kind: UInt8, Sendable {
        /// A main-actor job (`Task { @MainActor }`, an `await` that resumes on the main actor, a continuation).
        case mainActor = 0
        /// A ``MainDelivery`` hop from another thread (a main-queue block).
        case mainDelivery = 1
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
        public var runNanos: UInt64
        /// The QoS class raw value (`JobPriority` / `qos_class_t`), 0 unspecified.
        public var priority: UInt8
        /// Return addresses, the innermost first (the ring's own frames included).
        public var frames: [UInt]
    }

    /// The return addresses kept per job: the runtime's enqueue frames, then the enqueuer's.
    public static let depth = 12

    public let capacity: Int
    private let clock: @Sendable () -> UInt64
    private let claims = Atomic<Int>(0)
    private let frozen = Atomic<Bool>(false)
    // Written by the claiming thread before it queues the job.
    private let kinds: UnsafeMutablePointer<UInt8>
    private let enqueued: UnsafeMutablePointer<UInt64>
    private let priorities: UnsafeMutablePointer<UInt8>
    private let frameCounts: UnsafeMutablePointer<Int32>
    private let frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>
    // Main thread only.
    private let runNanos: UnsafeMutablePointer<UInt64>
    private let ran: UnsafeMutablePointer<Bool>
    private let tally: UnsafeMutablePointer<Tally>

    /// - Parameters:
    ///   - capacity: The jobs kept (one slot each, about 130 bytes).
    ///   - clock: `CLOCK_UPTIME_RAW` nanoseconds (tests pass their own).
    public init(capacity: Int, clock: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }) {
        let count = max(capacity, 1)
        self.capacity = count
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
        unsafe runNanos = .allocate(capacity: count)
        unsafe runNanos.initialize(repeating: 0, count: count)
        unsafe ran = .allocate(capacity: count)
        unsafe ran.initialize(repeating: false, count: count)
        unsafe tally = .allocate(capacity: 1)
        unsafe tally.initialize(to: Tally())
    }

    /// `CLOCK_UPTIME_RAW` nanoseconds now, on the ring's clock.
    public var now: UInt64 { clock() }

    // MARK: Recording

    /// Claims a slot and records an enqueue now, from any thread: its kind, `priority` (a QoS class raw value) and
    /// the calling thread's return addresses. Nil when the ring is full or frozen (the drop is counted).
    public func recordEnqueue(_ kind: Kind, priority: UInt8) -> Int? {
        guard !frozen.load(ordering: .relaxed) else { return nil }
        let slot = claims.add(1, ordering: .relaxed).oldValue
        guard slot < capacity else { return nil }
        // SAFETY: slot < capacity (the claim above), and only this thread writes these fields of the slot.
        unsafe kinds[slot] = kind.rawValue
        unsafe enqueued[slot] = clock()
        unsafe priorities[slot] = priority
        // SAFETY: backtrace writes at most `depth` addresses, into the slot's own `depth` entries of `frames`.
        unsafe frameCounts[slot] = backtrace(frames + slot * Self.depth, Int32(Self.depth))
        return slot
    }

    /// Main thread: the job of `slot` ran for `nanos`; it counts in the tally.
    public func recordRun(slot: Int, nanos: UInt64) {
        guard slot >= 0, slot < capacity else { return }
        // SAFETY: slot is under capacity (checked above); the run fields and the tally are main-thread only.
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

    /// `work`, timed into the ring when it is recorded: ``MainDelivery``'s off-main hop. Unchanged when the ring is
    /// full or frozen.
    public func timed(_ work: @escaping @MainActor @Sendable () -> Void) -> @MainActor @Sendable () -> Void {
        guard let slot = recordEnqueue(.mainDelivery, priority: UInt8(truncatingIfNeeded: qos_class_self().rawValue)) else { return work }
        return { [self] in
            let start = clock()
            work()
            recordRun(slot: slot, nanos: clock() &- start)
        }
    }

    /// The hook's work for one main-actor job: recorded, then run on the main dispatch queue at its QoS between two
    /// clock reads; or, when the ring is full or frozen, given to the runtime's own enqueue.
    func enqueue(_ job: UnownedJob, original: Original) {
        let priority = job.priority.rawValue
        guard let slot = recordEnqueue(.mainActor, priority: priority) else { return original(job) }
        let qos = DispatchQoS.QoSClass(rawValue: qos_class_t(rawValue: UInt32(priority))) ?? .unspecified
        // main-async-allow: the Swift runtime's main executor puts every main-actor job on this queue at its QoS; the ring keeps the job's place and QoS there
        DispatchQueue.main.async(qos: DispatchQoS(qosClass: qos, relativePriority: 0)) { [self] in
            let start = clock()
            job.runSynchronously(on: MainActor.sharedUnownedExecutor)
            recordRun(slot: slot, nanos: clock() &- start)
        }
    }

    // MARK: Reading

    /// Main thread: the jobs that ran, in claim order; the jobs claimed and not run yet; the jobs dropped.
    public func read() -> (jobs: [Job], pending: Int, dropped: Int) {
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
                                   runNanos: runNanos[slot], priority: priorities[slot], frames: addresses))
        }
        return (jobs, kept - jobs.count, max(0, claimed - capacity))
    }

    // MARK: The runtime hook

    /// The installed ring's address (`Unmanaged`, retained for the process), 0 before an install. The runtime's hook
    /// is a thin function with no context, and ``MainDelivery`` has none to pass: this word is how both find the
    /// ring the composition root made.
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

    /// Sends every main-actor job and ``MainDelivery`` hop of the process through this ring. Once per process, in
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
