#if DEBUG || CMUX_BENCH_HOOKS
public import Dispatch
import CmuxNextCompat
import Foundation

/// The input-turn hop recorder (plans/cmux-next/chrome-parity/p04-input.md, task 022; machine queue
/// MQ-input-turn-hops): every main-thread hop that runs beside a person's input, by its site.
///
/// Two producers write it:
/// - the MainJobGate hook (task 021) calls ``recordEnqueue(turn:origin:priority:)`` for each
///   main-actor job enqueued while input is pending or dispatching: the recorder keeps the job's
///   stack (``HopRecord/depth`` return addresses, through the awaiting task's async frames), its
///   origin (the main thread or another) and priority;
/// - ``InputTurnCalloutTimer`` times each non-Swift callout of the main run loop (a timer, a GCD main
///   block or a mach-port source after a wake, and the run loop's source and block pass) with
///   input pending at its start or its end, and ``CalloutStackSampler`` names a long one's site.
///
/// Recording is lock-free and allocation-free: a fixed ring of ``pendingLimit`` records
/// (``HopRing``); a full ring counts the record in ``Snapshot/dropped``. The fold runs off the main
/// thread: the callout timer wakes it once per main run-loop turn that left records, and a snapshot
/// folds what is left. It resolves each stack to image + offset frames (`dladdr`), picks the first
/// frame after the runtime frames the enqueue went through, and counts the hop under that site, at
/// most ``siteLimit`` sites; a sampled callout counts under its site, another under its stretch. Chrome answers the same question with its task annotator: every task
/// carries its `posted_from` location (`base/task/common/task_annotator.cc`), and the input
/// scheduler's queueing time is attributed to the tasks that ran ahead of the input
/// (`third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`).
///
/// `debug.input` action `hops` reads it (CmuxNextInputDiagnostics), and
/// `scripts/cmux-next/input-turn-hops.py` symbolicates its sites to file:line with the dSYM.
///
/// ```swift
/// let hops = MainJobGateDiagnostics()
/// let sampler = CalloutStackSampler { mainStack.sample() }
/// let timer = InputTurnCalloutTimer(diagnostics: hops, sampler: sampler) { inputPendingState.turn }
/// // The MainJobGate hook, while input is pending or dispatching:
/// hops.recordEnqueue(turn: turn, origin: pthread_main_np() != 0 ? .main : .offMain, priority: priority)
/// let rows = hops.snapshot(sinceLaunch: true).rows
/// ```
public final class MainJobGateDiagnostics: Sendable {
    /// The most sites a snapshot holds; a hop at a further site counts in ``Snapshot/sitesOverflow``.
    public static let siteLimit = 128
    /// The most records that wait for the fold; a further record counts in ``Snapshot/dropped``.
    public static let pendingLimit = 64

    /// Where the fold runs.
    public enum Folding: Sendable {
        /// On a utility queue the callout timer wakes, and on a snapshot's thread (the app).
        case background
        /// As ``background``, on `queue` (tests: a serial queue they wait on).
        case queue(DispatchQueue)
        /// Only in ``fold()`` and a snapshot (tests).
        case manual
    }

    /// Who enqueued a main-actor job.
    public enum Origin: UInt8, Sendable, CaseIterable {
        case main, offMain

        var name: String { self == .main ? "main" : "off_main" }
    }

    /// The input of the turn a hop ran in: the kinds pending (``SessionInputPending/Kinds``'s bits)
    /// and whether an event was being dispatched.
    public struct InputTurn: OptionSet, Sendable, Hashable {
        /// The bits as a number.
        public let rawValue: UInt8
        /// Bits from their number.
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// A key press was pending.
        public static let key = InputTurn(rawValue: 1 << 0)
        /// A mouse button press was pending.
        public static let click = InputTurn(rawValue: 1 << 1)
        /// A scroll begin was pending.
        public static let scrollBegin = InputTurn(rawValue: 1 << 2)
        /// A drag was pending.
        public static let drag = InputTurn(rawValue: 1 << 3)
        /// An event was in dispatch.
        public static let dispatching = InputTurn(rawValue: 1 << 4)

        /// The kinds `pending` names, and ``dispatching`` when `dispatching`.
        public init(pending: SessionInputPending.Kinds, dispatching: Bool) {
            self.init(rawValue: pending.rawValue & 0x0F | (dispatching ? Self.dispatching.rawValue : 0))
        }

        /// The JSON names, in bit order.
        var names: [String] {
            let named: [(InputTurn, String)] = [(.key, "key"), (.click, "click"), (.scrollBegin, "scroll_begin"), (.drag, "drag"),
                                                (.dispatching, "dispatching")]
            return named.compactMap { contains($0.0) ? $0.1 : nil }
        }
    }

    /// A Swift job or a non-Swift callout.
    public enum Lane: UInt8, Sendable, Encodable {
        case swift, nonswift

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(self == .swift ? "swift" : "nonswift")
        }
    }

    /// The run-loop stretch a non-Swift callout ran in. After a wake the run loop handles one of a
    /// timer, the main dispatch queue or a mach-port source; a timer due at the wake names it a
    /// timer. The source pass runs the version-0 sources and the blocks, and when CFRunLoop's poll
    /// then finds the main dispatch queue's port ready it drains that queue in the same stretch
    /// (CFRunLoop.c `__CFRunLoopRun`: `goto handle_msg` skips the wait and its observers). The main
    /// queue runs the Swift main-actor jobs: a stretch that can drain it is ``Row/includesSwiftJobs``.
    public enum CalloutKind: UInt8, Sendable, CaseIterable {
        case timer, mainQueueOrPort, sources

        /// A row's ``Row/callouts`` name.
        var name: String {
            switch self {
            case .timer: "timer"
            case .mainQueueOrPort: "main_queue_or_port"
            case .sources: "sources_or_polled_main_queue"
            }
        }

        /// The row of the stretches that were not sampled.
        var site: String { "runloop." + name }
    }

    /// The main run loop's mode during a callout: a non-Swift row's origin.
    public enum RunLoopModeName: UInt8, Sendable, CaseIterable {
        case `default`, eventTracking, modalPanel, other

        var name: String {
            switch self {
            case .default: "default"
            case .eventTracking: "event_tracking"
            case .modalPanel: "modal_panel"
            case .other: "other"
            }
        }
    }

    let ring = HopRing(capacity: MainJobGateDiagnostics.pendingLimit)
    private let droppedCount = Atomic<UInt64>(0)
    /// A background fold is queued and has not started.
    private let foldQueued = Atomic<Bool>(false)
    private let foldQueue: DispatchQueue?
    // concurrency-allow: the fold's site tables (lock carve-out: the main thread never takes it; it is held to fold at most `pendingLimit` records or to copy a snapshot, no I/O under it).
    private let folded: Mutex<HopSites>

    /// - Parameter folding: Where the fold runs (default: in the background).
    public convenience init(folding: Folding = .background) {
        self.init(folding: folding, entry: HopFrameResolver.concurrencyRuntime)
    }

    /// - Parameters:
    ///   - folding: Where the fold runs.
    ///   - entry: The image that calls ``recordEnqueue(turn:origin:priority:)``'s caller (the hook's
    ///     caller, libswift_Concurrency; tests: libdispatch, through `DispatchQueue.sync`).
    init(folding: Folding, entry: String) {
        folded = Mutex(HopSites(entry: entry))
        switch folding {
        case .background: foldQueue = DispatchQueue.global(qos: .utility)
        case let .queue(queue): foldQueue = queue
        case .manual: foldQueue = nil
        }
    }

    // MARK: Producers (any thread; no allocation, lock or system call)

    /// A main-actor job was enqueued while input is pending or dispatching (the MainJobGate hook):
    /// keeps the caller's stack, `origin` and `priority` (the job's raw `TaskPriority`).
    // perf-hot: 2us main-job-gate
    @inline(never)
    public func recordEnqueue(turn: InputTurn, origin: Origin, priority: UInt8) {
        var record = HopRecord(lane: .swift, origin: origin.rawValue, priority: priority, turn: turn)
        record.captureStack()
        push(record)
    }

    /// A non-Swift callout of the main run loop with input pending at its start or end took `nanos`.
    func recordCallout(_ callout: CalloutKind, mode: RunLoopModeName, turn: InputTurn, nanos: UInt64) {
        push(HopRecord(lane: .nonswift, origin: mode.rawValue, turn: turn, callout: callout, nanos: nanos))
    }

    func push(_ record: HopRecord) {
        if !ring.push(record) { droppedCount.add(1, ordering: .relaxed) }
    }

    /// Queues a fold when records wait (the callout timer, at the stages that end a stretch).
    func wakeFold() {
        guard let foldQueue, ring.count > 0, !foldQueued.exchange(true, ordering: .acquiringAndReleasing) else { return }
        foldQueue.async { [weak self] in
            guard let self else { return }
            foldQueued.store(false, ordering: .releasing)
            fold()
        }
    }

    // MARK: Consumer (never the main thread)

    /// Moves every published record into the site tables, on the caller's thread.
    public func fold() {
        folded.withLock { sites in
            while let record = ring.pop() { sites.add(record) }
        }
    }

    /// The sites since launch, or since the last ``reset()``, most hops first (folds first).
    public func snapshot(sinceLaunch: Bool) -> Snapshot {
        folded.withLock { sites in
            while let record = ring.pop() { sites.add(record) }
            // Read under the lock, as a reset reads it: the since-reset count never goes below zero.
            return sites.snapshot(sinceLaunch: sinceLaunch, dropped: droppedCount.load(ordering: .relaxed), pending: ring.count)
        }
    }

    /// ``snapshot(sinceLaunch:)`` on the global executor, never the caller's (the main actor's
    /// included): the fold resolves stacks with `dladdr`, which takes dyld's lock.
    @concurrent
    public func resolvedSnapshot(sinceLaunch: Bool) async -> Snapshot {
        snapshot(sinceLaunch: sinceLaunch)
    }

    /// Starts the since-reset window over (`debug.input` action `reset`); the since-launch sites stay.
    public func reset() {
        folded.withLock { sites in
            while let record = ring.pop() { sites.add(record) }
            sites.reset(dropped: droppedCount.load(ordering: .relaxed))
        }
    }
}

extension MainJobGateDiagnostics {
    /// The recorder's rows (`debug.input` action `hops`).
    public struct Snapshot: Sendable, Encodable, Equatable {
        /// Since launch (true) or since the last reset.
        public var sinceLaunch: Bool
        /// Hops folded in this window.
        public var recorded: UInt64
        /// Hops the full ring refused in this window.
        public var dropped: UInt64
        /// Hops at a site past ``MainJobGateDiagnostics/siteLimit`` in this window.
        public var sitesOverflow: UInt64
        /// Hops written and not folded yet.
        public var pending: Int
        /// One row per site, most hops first.
        public var rows: [Row]

        enum CodingKeys: String, CodingKey {
            case sinceLaunch = "since_launch", recorded, dropped, sitesOverflow = "sites_overflow", pending, rows
        }
    }

    /// One site: a Swift job's first frame past the runtime, a sampled non-Swift callout's site, or
    /// the run-loop stretch of unsampled callouts.
    public struct Row: Sendable, Encodable, Equatable {
        /// `image+0xoffset` (a resolved Swift or sampled callout site), `0xaddress` (unresolved),
        /// `truncated` (a Swift stack with no site: no entry frame, or none past the runtime) or `runloop.<stretch>`
        /// (unsampled non-Swift callouts).
        public var site: String
        /// Whether the site is a Swift job or a non-Swift callout.
        public var lane: Lane
        /// The hops counted at the site.
        public var count: Int
        /// The input kinds of the turns the site's hops ran in (`key`, `click`, `scroll_begin`, `drag`,
        /// `dispatching`).
        public var kinds: [String]
        /// Hops per origin: `main` and `off_main` (Swift), the run-loop mode (non-Swift).
        public var origin: [String: Int]
        /// The jobs' raw `TaskPriority` values (Swift).
        public var priorities: [Int]
        /// The run-loop stretches the callouts ran in (``CalloutKind`` names; non-Swift).
        public var callouts: [String]?
        /// Whether the callouts' time can include Swift main-actor jobs, which the swift lane counts
        /// by their enqueue (non-Swift): a sampled callout that ran one, or an unsampled stretch
        /// that can drain the main queue.
        public var includesSwiftJobs: Bool?
        /// Time in the callouts (non-Swift).
        public var totalMilliseconds: Double?
        /// The longest callout (non-Swift).
        public var maxMilliseconds: Double?
        /// The site's frame (resolved).
        public var frame: Frame?
        /// The first hop's stack, innermost first (Swift: from the capture; a sampled callout: the
        /// innermost frames up to its site, which is the last).
        public var stack: [Frame]

        enum CodingKeys: String, CodingKey {
            case site, lane, count, kinds, origin, priorities, callouts, includesSwiftJobs = "includes_swift_jobs"
            case totalMilliseconds = "total_ms", maxMilliseconds = "max_ms", frame, stack
        }
    }

    /// One return address as image + offset: enough to symbolicate with the image's dSYM.
    public struct Frame: Sendable, Encodable, Equatable {
        /// The image's name.
        public var image: String
        /// The image's UUID, which names its dSYM; nil when it could not be read.
        public var imageUUID: String?
        /// The return address minus the image's load address.
        public var offset: UInt64
        /// `dladdr`'s nearest exported symbol before the call (mangled; wrong in a stripped image's
        /// local functions: the script's dSYM lookup is the name).
        public var nearestSymbol: String?

        enum CodingKeys: String, CodingKey {
            case image, imageUUID = "image_uuid", offset, nearestSymbol = "nearest_symbol"
        }
    }
}
#endif
