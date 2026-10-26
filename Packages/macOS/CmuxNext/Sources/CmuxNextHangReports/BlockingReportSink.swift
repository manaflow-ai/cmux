public import CmuxNextCompat
public import Foundation

/// Where the blocking detector's new call sites go (the app's `WatchdogReporting` installs it once):
/// each site to opt-in hang reports as one ``HangSample/Kind/blocking`` sample (once their wire schema
/// carries them, ``HangReport/WireSchema/carriesBlocking``), and, only while crash reporting runs (the
/// person's crash-report consent), to Sentry as one non-fatal ``NonFatalEvent`` within
/// ``BlockingReportBudget`` (5 per launch, 1 per site per 24 h).
///
/// ``record(_:)`` runs on the detector's drain queue (`com.cmuxterm.app.next.blocking-drain`, utility),
/// never on the thread that blocked. Nothing it sends holds a path, file name or symbol: the kind, the
/// violation's ``BlockingContext`` (the main thread, a shared pool thread or a `.cpu` lane item) and
/// image UUID + offset frames only.
///
/// ```swift
/// services.blocking.install(sink: BlockingReportSink(collector: collector, nonFatal: .init(
///     consented: { reporter.isStarted },
///     send: { reporter.captureNonFatal($0.message, type: $0.type, fingerprint: $0.fingerprint, tags: $0.tags, extra: $0.extra) })))
/// ```
public final class BlockingReportSink: BlockingViolationSink {
    /// When each site was last sent to Sentry (``BlockingReportBudget/lastSent``), in the app's defaults.
    public static let lastSentKey = "cmux.next.blockingReports.lastSent"

    /// One non-fatal crash-report event: one issue per site.
    public struct NonFatalEvent: Sendable, Equatable {
        /// The event's message (the thread and the kind only).
        public var message: String
        /// The exception type.
        public var type: String
        /// Groups the events of one site.
        public var fingerprint: [String]
        /// The kind and the context.
        public var tags: [String: String]
        /// The frames as `UUID+0xoffset` lines, for symbolication.
        public var extra: [String: String]

        /// The event of `violation` at `site` (``BlockingReportBudget/site(of:)``): its message, type and
        /// fingerprint name the thread it ran on (`main-thread blocking: file-io`, `pool-thread blocking: sync-wait`).
        public init(violation: BlockingViolation, site: String) {
            let thread = Self.thread(violation.context)
            message = "\(thread.label) blocking: \(violation.kind.rawValue)"
            type = "\(thread.type)Blocking"
            fingerprint = ["\(thread.label)-blocking", site]
            tags = ["blocking_kind": violation.kind.rawValue, "blocking_context": violation.context.rawValue]
            extra = ["frames": violation.frames.map { "\($0.imageUUID.uuidString)+0x\(String($0.offset, radix: 16))" }
                .joined(separator: "\n")]
        }

        /// The thread's name in the message and fingerprint, and in the type.
        private static func thread(_ context: BlockingContext) -> (label: String, type: String) {
            switch context {
            case .main: ("main-thread", "MainThread")
            case .pool: ("pool-thread", "PoolThread")
            case .lane: ("lane", "Lane")
            case .dedicated: ("dedicated-thread", "DedicatedThread")
            case .cpuLane: ("cpu-lane", "CpuLane")
            case .laneSync: ("lane-sync", "LaneSync")
            }
        }
    }

    /// The crash-report side: whether it may send now, and the send.
    public struct NonFatal: Sendable {
        /// Whether crash reporting runs (consent given, not managed off, not a test).
        public var consented: @Sendable () -> Bool
        /// Sends one event.
        public var send: @Sendable (NonFatalEvent) -> Void

        /// Makes the value from its parts.
        public init(consented: @escaping @Sendable () -> Bool, send: @escaping @Sendable (NonFatalEvent) -> Void) {
            self.consented = consented
            self.send = send
        }
    }

    /// The saved ``BlockingReportBudget/lastSent`` times.
    public struct LastSentStore: Sendable {
        /// Reads the saved times (once, at the first consented site).
        public var load: @Sendable () -> [String: Date]
        /// Saves the times after each admitted site.
        public var save: @Sendable ([String: Date]) -> Void

        /// Makes the value from its parts.
        public init(load: @escaping @Sendable () -> [String: Date], save: @escaping @Sendable ([String: Date]) -> Void) {
            self.load = load
            self.save = save
        }

        /// The times under ``BlockingReportSink/lastSentKey`` in the standard defaults (thread-safe).
        public static let standardDefaults = LastSentStore(
            load: { UserDefaults.standard.dictionary(forKey: BlockingReportSink.lastSentKey)?.compactMapValues { $0 as? Date } ?? [:] },
            save: { UserDefaults.standard.set($0, forKey: BlockingReportSink.lastSentKey) })
    }

    private let collector: HangReportCollector?
    private let nonFatal: NonFatal
    private let store: LastSentStore
    private let now: @Sendable () -> Date
    // Lock carve-out: only the detector's serial drain queue calls record, so it is never contended;
    // the lock only makes the class Sendable. Nil until the first consented site loads the saved times.
    private let budget = Mutex<BlockingReportBudget?>(nil)

    /// Makes the value from its parts.
    ///
    /// - Parameters:
    ///   - collector: This launch's hang report collector; nil where hang reports never send.
    ///   - nonFatal: The crash-report side.
    ///   - store: Where the last-sent times persist.
    ///   - now: The clock of the 24 h rule.
    public init(collector: HangReportCollector?, nonFatal: NonFatal, store: LastSentStore = .standardDefaults,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.collector = collector
        self.nonFatal = nonFatal
        self.store = store
        self.now = now
    }

    /// Takes one new site (the detector's drain queue).
    public func record(_ violation: BlockingViolation) {
        collector?.noteBlocking(violation)
        guard nonFatal.consented() else { return }
        let site = BlockingReportBudget.site(of: violation)
        let store = store
        let at = now()
        let admitted: [String: Date]? = budget.withLock { budget in
            var current = budget ?? BlockingReportBudget(lastSent: store.load())
            let admits = current.admit(site: site, now: at)
            budget = current
            return admits ? current.lastSent : nil
        }
        guard let admitted else { return }
        store.save(admitted)
        nonFatal.send(NonFatalEvent(violation: violation, site: site))
    }
}
