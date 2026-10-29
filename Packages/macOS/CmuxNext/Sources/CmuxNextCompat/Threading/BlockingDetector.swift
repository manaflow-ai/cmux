/// The handle to the main-thread blocking detector that other modules hold: the composition root makes
/// it once with ``forProcess()`` and passes it to what installs the sink (the app's hang reports wiring),
/// the `debug.blocking` control method and the Debug menu.
///
/// In Debug, bench-checks and nightly-next builds (`-DCMUX_BLOCKING_CHECKS`) it refers to the detector's
/// process-wide table (see ``blockingCall(_:fileID:line:_:)``); in Release it reads as empty and its calls do
/// nothing, and no detector code is in the app (`scripts/measure/blocking-checks.sh --app APP --expect release`).
///
/// ```swift
/// let blocking = BlockingDetector.forProcess()      // AppServices (the composition root) only
/// BlockingControl(detector: blocking).method        // debug.blocking
/// ```
public struct BlockingDetector: Sendable {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    let table: BlockingViolationTable

    /// A detector over `table` (tests: the checks report to it inside its task-local scope).
    init(table: BlockingViolationTable) {
        self.table = table
    }
    #else
    private init() {}
    #endif

    /// The process's detector. Call it once, in the composition root (AppServices), and pass the value on;
    /// no other code makes one (P1, plans/cmux-next/PATTERNS.md). It also installs the detector as the shared
    /// packages' blocking-call hook (``SharedThreadingBridge``), once per process, in every build.
    ///
    /// - Returns: The handle to this process's detector.
    public static func forProcess() -> BlockingDetector {
        SharedThreadingBridge.installForProcess()
        #if DEBUG || CMUX_BLOCKING_CHECKS
        return BlockingDetector(table: .shared)
        #else
        return BlockingDetector()
        #endif
    }

    /// Whether this build has the detector (Debug, bench-checks and nightly-next builds).
    public var isCompiledIn: Bool {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        true
        #else
        false
        #endif
    }

    /// What a violation does: ``BlockingMode/record`` by default in every checked build (Debug, bench-checks,
    /// Nightly); ``BlockingMode/trap`` when a Debug or Nightly launch set `CMUX_BLOCKING_TRAP=1`
    /// (``BlockingMode/resolved(environment:)``: it hands the site to the sink, waiting at most 50 ms, then stops);
    /// a bench build never traps; always ``BlockingMode/record`` in Release.
    public var mode: BlockingMode {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.mode
        #else
        .record
        #endif
    }

    /// What a violation on a shared pool thread does (``BlockingMode/record`` in every build but a Debug build
    /// started with `CMUX_BLOCKING_TRAP_POOL=1`).
    public var poolMode: BlockingMode {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.poolMode
        #else
        .record
        #endif
    }

    /// Installs the sink that receives each new call site once, on the drain queue (the last call
    /// wins; nil removes it). The sink first gets every site recorded before the call, so the
    /// launch's sites before the composition root ran are not lost.
    public func install(sink: (any BlockingViolationSink)?) {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.install(sink: sink)
        #endif
    }

    /// How long one drain-queue job (a drain pass, or the replay to a new sink) may run before the hang watch the
    /// composition root sets with ``watchDrain(_:)`` reports it: it resolves stacks and calls the sink, no wait.
    public static let drainHangDeadline: Duration = .seconds(10)

    /// Runs each drain-queue job through `watch`, so the drain queue is a hang-watched lane. Compat sits below
    /// the hang watch (CmuxNextTrace) and cannot import it, so the composition root passes a closure that runs
    /// the job inside one scope of its lane (p09-observability.md, layer rule 8). The last call wins; nil runs
    /// the jobs unwatched again.
    ///
    /// ```swift
    /// let lane = HangWatchedLane("blocking.drain", deadline: BlockingDetector.drainHangDeadline, on: hangWatch)
    /// blocking.watchDrain { job in lane.run(job) }
    /// ```
    public func watchDrain(_ watch: BlockingDrainWatch?) {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.watchDrain(watch)
        #endif
    }

    /// The call sites that blocked the main thread, a shared pool thread or a `.cpu` lane item, or waited on a sync
    /// primitive in a lane item, and reached the drain queue, in the order they first did, with their current counts.
    public var sites: [BlockingSite] {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.sites
        #else
        []
        #endif
    }

    /// The call sites that blocked the main thread (``BlockingContext/main``), with their counts and wall times
    /// since launch: what the opt-in hang reports' `blocking_sites` count. Each count is the
    /// site's relaxed atomic, which a repeat of a known site only increments: the stack is captured once, the
    /// first time the site is seen. Empty in Release. Allocates; read it off the main thread.
    public var mainThreadSites: [BlockingSite] {
        sites.filter { $0.context == .main }
    }

    /// ``mainThreadSites`` with the count of ``resetCounts()`` calls they follow, so a reader that keeps a
    /// baseline knows when the counters went back to zero instead of guessing it from smaller values.
    public var mainThreadRead: MainThreadRead {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        // The reset count first: a reset stores it after zeroing, so a new value means the sites read zeroed.
        let resets = table.resetCount
        return MainThreadRead(resets: resets, sites: mainThreadSites)
        #else
        return MainThreadRead()
        #endif
    }

    /// Blocking calls, on the main thread, the pool, a `.cpu` lane item or a lane item's sync primitive, not recorded
    /// as a site (the sum of
    /// ``overflow(in:)`` over the contexts).
    public var overflow: Int {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.overflow
        #else
        0
        #endif
    }

    /// Blocking calls in `context` not recorded as a site: its table was full (128 sites per context per
    /// launch), or 64 of its new sites were already waiting for the drain (such a site is recorded on a later
    /// call). Always 0 for ``BlockingContext/lane`` and ``BlockingContext/dedicated``, which may block.
    ///
    /// - Parameter context: The context to read.
    /// - Returns: Its unrecorded calls since launch.
    public func overflow(in context: BlockingContext) -> Int {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.overflow(in: context)
        #else
        0
        #endif
    }

    /// The call sites where a thread waited on a queue of a lower QoS than its own (``BlockingQoSInversion``), in
    /// the order they first reached the drain queue, with their current counts. Recorded by the waiting seams
    /// (``Dispatch/DispatchQueue/blockingSync(fileID:line:execute:)``) on any thread; empty in Release, which
    /// compiles the check out.
    public var qosInversions: [BlockingQoSInversion] {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.qosInversions.inversions
        #else
        []
        #endif
    }

    /// QoS inversions not recorded as a site: 64 sites per launch were already known, or 64 new ones were waiting
    /// for the drain. 0 in Release.
    public var qosInversionOverflow: Int {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.qosInversions.overflow
        #else
        0
        #endif
    }

    /// Zeroes every site's count and wall times (between sweep steps), QoS inversion sites included, and adds one
    /// to ``MainThreadRead/resets``; the sites stay known, so a site that blocks again is counted, not sent to the
    /// sink again.
    public func resetCounts() {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.resetCounts()
        #endif
    }
}

extension BlockingDetector {
    /// One read of the main thread's sites (``BlockingDetector/mainThreadRead``).
    public struct MainThreadRead: Sendable, Equatable {
        /// How many ``BlockingDetector/resetCounts()`` calls finished before ``sites`` was read: the counts are
        /// since the last of them.
        public var resets: Int
        /// The main-thread sites, with their counts since launch or since the last reset.
        public var sites: [BlockingSite]

        /// Makes the value from its parts (a build without the detector reads no reset and no site).
        public init(resets: Int = 0, sites: [BlockingSite] = []) {
            self.resets = resets
            self.sites = sites
        }
    }
}

/// Runs one job of the blocking detector's drain queue: call `job` exactly once, synchronously, on the calling
/// thread (``BlockingDetector/watchDrain(_:)``).
public typealias BlockingDrainWatch = @Sendable (_ job: () -> Void) -> Void
