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
/// ``record(daemonSite:)`` takes the daemon's sites (``DaemonDiagnosticSite/Sighting``, the
/// `server-diagnostic-site` events of the local daemon) the same way, with the daemon as their
/// source: each pair of daemon life and site once across launches (``DaemonSiteLedger``), as one
/// ``HangSample/Source/daemon`` sample (in slots of their own, ``StallAggregate/maxDaemonSamples``) and a
/// non-fatal event within a budget of its own, so a daemon's replay never takes the app's own sites' room.
/// The app calls it on a background lane, never on the connection's reader thread.
///
/// ```swift
/// services.blocking.install(sink: BlockingReportSink(collector: collector, nonFatal: .init(
///     consented: { reporter.isStarted },
///     send: { reporter.captureNonFatal($0.message, type: $0.type, fingerprint: $0.fingerprint, tags: $0.tags, extra: $0.extra) })))
/// ```
public final class BlockingReportSink: BlockingViolationSink {
    /// When each site was last sent to Sentry (``BlockingReportBudget/lastSent``), in the app's defaults.
    public static let lastSentKey = "cmux.next.blockingReports.lastSent"
    /// The same for the daemon's sites, whose budget is their own.
    public static let daemonLastSentKey = "cmux.next.blockingReports.daemonLastSent"

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

        /// The event of the daemon site `site`: `daemon blocking: fs`, `daemon inversion: priority-inversion`,
        /// `daemon hang: request`, grouped by the site's ``DaemonDiagnosticSite/key``.
        public init(daemonSite site: DaemonDiagnosticSite) {
            message = "daemon \(site.family.rawValue): \(site.kind)"
            type = switch site.family {
            case .blocking: "DaemonBlocking"
            case .inversion: "DaemonInversion"
            case .hang: "DaemonHang"
            }
            fingerprint = ["daemon-\(site.family.rawValue)", site.key]
            tags = ["blocking_kind": site.kind, "blocking_context": "daemon"]
            extra = ["site": site.key]
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
        public static let standardDefaults = defaults(key: BlockingReportSink.lastSentKey)
        /// The daemon sites' times under ``BlockingReportSink/daemonLastSentKey``.
        public static let daemonDefaults = defaults(key: BlockingReportSink.daemonLastSentKey)

        private static func defaults(key: String) -> LastSentStore {
            LastSentStore(load: { UserDefaults.standard.dictionary(forKey: key)?.compactMapValues { $0 as? Date } ?? [:] },
                          save: { UserDefaults.standard.set($0, forKey: key) })
        }
    }

    /// One Sentry budget and where its times persist.
    private final class Budget: Sendable {
        let store: LastSentStore
        // Lock carve-out: each admit and its save run under it so two admits never save out of order (a
        // UserDefaults set, no wait); taken once per new site, never on the thread that blocked.
        // Nil until the first consented site loads the saved times.
        let state = Mutex<BlockingReportBudget?>(nil)

        init(store: LastSentStore) {
            self.store = store
        }

        /// Whether `site` may be sent at `now`; when it may, the new times are saved before the lock is let go.
        func admit(site: String, now: Date) -> Bool {
            let store = store
            return state.withLock { budget in
                var current = budget ?? BlockingReportBudget(lastSent: store.load())
                let admits = current.admit(site: site, now: now)
                budget = current
                if admits { store.save(current.lastSent) }
                return admits
            }
        }
    }

    private let collector: HangReportCollector?
    private let nonFatal: NonFatal
    private let now: @Sendable () -> Date
    /// The app's own sites (the detector's serial drain queue).
    private let budget: Budget
    /// The daemon's sites (one background lane item per new site, a few per daemon life).
    private let daemonBudget: Budget
    private let daemonSiteStore: DaemonSiteLedger.Store
    // Lock carve-out: each daemon site's admit and its save run under it so two lane items never save out of
    // order (a UserDefaults set, no wait). Nil until the first daemon site loads the saved ledger.
    private let daemonSites = Mutex<DaemonSiteLedger?>(nil)

    /// Makes the value from its parts.
    ///
    /// - Parameters:
    ///   - collector: This launch's hang report collector; nil where hang reports never send.
    ///   - nonFatal: The crash-report side.
    ///   - store: Where the app sites' last-sent times persist.
    ///   - daemonStore: Where the daemon sites' last-sent times persist.
    ///   - daemonSites: Where the daemon sites reported per daemon life persist.
    ///   - now: The clock of the 24 h rule.
    public init(collector: HangReportCollector?, nonFatal: NonFatal, store: LastSentStore = .standardDefaults,
                daemonStore: LastSentStore = .daemonDefaults, daemonSites: DaemonSiteLedger.Store = .standardDefaults,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.collector = collector
        self.nonFatal = nonFatal
        self.budget = Budget(store: store)
        self.daemonBudget = Budget(store: daemonStore)
        self.daemonSiteStore = daemonSites
        self.now = now
    }

    /// Takes one new site (the detector's drain queue).
    public func record(_ violation: BlockingViolation) {
        collector?.noteBlocking(violation)
        send(site: BlockingReportBudget.site(of: violation), within: budget) { NonFatalEvent(violation: violation, site: $0) }
    }

    /// Takes one daemon site (a background lane): nothing when this install already reported it for that
    /// daemon life, else its sample and its non-fatal event within the daemon sites' budget.
    public func record(daemonSite sighting: DaemonDiagnosticSite.Sighting) {
        let store = daemonSiteStore
        let isNew = daemonSites.withLock { ledger in
            var current = ledger ?? store.load()
            let admits = current.admit(sighting)
            ledger = current
            if admits { store.save(current) }
            return admits
        }
        guard isNew else { return }
        collector?.noteDaemonSite(sighting.site)
        send(site: sighting.site.key, within: daemonBudget) { _ in NonFatalEvent(daemonSite: sighting.site) }
    }

    /// Sends the event of `site` when crash reporting runs and `budget` admits it.
    private func send(site: String, within budget: Budget, event: (String) -> NonFatalEvent) {
        guard nonFatal.consented(), budget.admit(site: site, now: now()) else { return }
        nonFatal.send(event(site))
    }
}
