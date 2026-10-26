public import CmuxNextCompat
public import Foundation

/// Where the main-thread blocking detector's new call sites go (the app's `WatchdogReporting` installs
/// it once): each site to opt-in hang reports as one ``HangSample/Kind/blocking`` sample, and, only
/// while crash reporting runs (the person's crash-report consent), to Sentry as one non-fatal
/// ``NonFatalEvent`` within ``BlockingReportBudget`` (5 per launch, 1 per site per 24 h).
///
/// ``record(_:)`` runs on the detector's drain queue (`com.cmuxterm.app.next.blocking-drain`, utility),
/// never on the thread that blocked. Nothing it sends holds a path, file name or symbol: the kind,
/// the context and image UUID + offset frames only.
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
        /// The event's message (the kind only).
        public var message: String
        /// The exception type.
        public var type: String
        /// Groups the events of one site.
        public var fingerprint: [String]
        /// The kind and the context.
        public var tags: [String: String]
        /// The frames as `UUID+0xoffset` lines, for symbolication.
        public var extra: [String: String]

        /// The event of `violation` at `site` (``BlockingReportBudget/site(of:)``).
        public init(violation: BlockingViolation, site: String, context: HangSample.Blocking.Context) {
            message = "main-thread blocking: \(violation.kind.rawValue)"
            type = "MainThreadBlocking"
            fingerprint = ["main-thread-blocking", site]
            tags = ["blocking_kind": violation.kind.rawValue, "blocking_context": context.rawValue]
            extra = ["frames": violation.frames.map { "\($0.imageUUID.uuidString)+0x\(String($0.offset, radix: 16))" }
                .joined(separator: "\n")]
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
        // The detector checks the main thread only, so every site it reports ran there.
        let context = HangSample.Blocking.Context.main
        collector?.noteBlocking(violation, context: context)
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
        nonFatal.send(NonFatalEvent(violation: violation, site: site, context: context))
    }
}
