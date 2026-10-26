/// The handle to the main-thread blocking detector that other modules hold: the composition root makes
/// it once with ``forProcess()`` and passes it to what installs the sink (the opt-in hang reports, once
/// they are wired), the `debug.blocking` control method and the Debug menu.
///
/// In Debug and bench builds (Nightly to come) it refers to the detector's process-wide table (see
/// ``blockingCall(_:fileID:line:_:)``); in Release it reads as empty and its calls do nothing.
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
    /// no other code makes one (P1, plans/cmux-next/PATTERNS.md).
    ///
    /// - Returns: The handle to this process's detector.
    public static func forProcess() -> BlockingDetector {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        BlockingDetector(table: .shared)
        #else
        BlockingDetector()
        #endif
    }

    /// Whether this build has the detector (Debug and bench builds; Nightly to come).
    public var isCompiledIn: Bool {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        true
        #else
        false
        #endif
    }

    /// What a violation does (``BlockingMode/record`` in every build but a Debug build started with
    /// `CMUX_BLOCKING_TRAP=1`).
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
    /// wins; nil removes it).
    public func install(sink: (any BlockingViolationSink)?) {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.install(sink: sink)
        #endif
    }

    /// The call sites that blocked the main thread or a shared pool thread and reached the drain queue, in the order they
    /// first did, with their current counts.
    public var sites: [BlockingSite] {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.sites
        #else
        []
        #endif
    }

    /// Blocking calls, on the main thread or the pool, not recorded as a site (the sum of
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

    /// Zeroes every site's count and wall times (between sweep steps); the sites stay known, so a site that
    /// blocks again is counted, not sent to the sink again.
    public func resetCounts() {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        table.resetCounts()
        #endif
    }
}
