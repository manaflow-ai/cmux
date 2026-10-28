#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextBrowser
public import CmuxNextDaemon
public import CmuxNextOracle

/// The oracle's `crashes` facet (schemas/oracle/snapshot-v1.schema.json `crashes`): the child
/// process exits of this app and its daemon, by kind, as totals the runner diffs between checkpoints. Invariant I17
/// fails a case on an exit no `allow_crashes` entry of the case covers.
///
/// Chromium fails a browser test on any renderer crash it did not allow (`NoRendererCrashesAssertion` and
/// `ScopedAllowRendererCrashes`, content/public/test/browser_test_base.h). The sources are the records the app and
/// the daemon already keep, read only when a snapshot asks:
/// - renderer, gpu, utility: Chromium's crash log (`CEFRuntime+Crashes`): the helper exits `CEFChildProcessMonitor`
///   sees, one per process, from the log's tallies so its 64-record ring never shortens a count.
/// - browser: the process that holds Chromium's browser process: the App's `CrashRecoveryService` (this launch
///   follows a run that ended unexpectedly), and with the Chromium Host on, the host's end (`CEFRuntime.hostEnded`).
/// - holder: the daemon's `oracle-state` `childExits`, the holders its owner counted ending.
/// - daemon: the app's connection, which counts each drop without `daemon-shutdown` (a crashed or killed owner
///   cannot count its own end; a requested stop announces itself and is not counted).
public nonisolated struct OracleCrashesFacet: OracleFacetProvider {
    /// The schema's crash kinds (`crashes.counts`, case-v1 `crashKind`).
    public nonisolated enum Kind: String, CaseIterable, Sendable, Hashable {
        case renderer, gpu, browser, utility, daemon, holder
    }

    /// One exit the app saw.
    public nonisolated struct Exit: Sendable, Hashable {
        public var kind: Kind
        public var reason: String
        public var exitCode: Int?

        public init(kind: Kind, reason: String, exitCode: Int?) {
            self.kind = kind
            self.reason = reason
            self.exitCode = exitCode
        }

        public var value: OracleValue {
            ["kind": .string(kind.rawValue), "reason": .string(reason), "exitCode": exitCode.map { OracleValue($0) } ?? .null]
        }
    }

    /// How the run this launch follows ended, when it ended unexpectedly (the App's `PreviousRun`).
    public nonisolated struct PreviousEnd: Sendable, Hashable {
        /// The fatal signal its handler wrote; nil when no handler ran (SIGKILL, jetsam).
        public var signal: Int32?
        /// An uncaught exception ended it.
        public var raisedException: Bool

        public init(signal: Int32?, raisedException: Bool) {
            self.signal = signal
            self.raisedException = raisedException
        }
    }

    /// The exits the app saw itself: exact totals by kind since launch, and the latest exits with their reasons.
    public nonisolated struct AppExits: Sendable, Hashable {
        /// Totals by kind, from the crash log's tallies (which outlive its ring) and the previous run.
        public var counts: [Kind: Int]
        /// The previous run's end, then the counted records still in the crash log's ring, oldest first (a detail;
        /// the counts do not read it).
        public var exits: [Exit]

        public init(counts: [Kind: Int], exits: [Exit]) {
            self.counts = counts
            self.exits = exits
        }

        /// - Parameters:
        ///   - previous: How the run this launch follows ended, when it ended unexpectedly.
        ///   - tallies: Chromium's crash log totals since launch (``BrowserCrashLog/tallies``).
        ///   - records: The crash log's latest records, oldest first.
        public init(previous: PreviousEnd?, tallies: [BrowserCrashTally: Int], records: [BrowserCrashRecord]) {
            var counts: [Kind: Int] = [:]
            var exits: [Exit] = []
            if let previous {
                let reason = previous.signal != nil ? "crashed" : previous.raisedException ? "exception" : "killed"
                exits.append(Exit(kind: .browser, reason: reason, exitCode: previous.signal.map { Int($0) }))
                counts[.browser] = 1
            }
            for (tally, total) in tallies {
                guard let kind = Self.countedKind(source: tally.source, processType: tally.processType) else { continue }
                counts[kind, default: 0] += total
            }
            for record in records {
                guard let kind = Self.countedKind(source: record.source, processType: record.processType) else { continue }
                exits.append(Exit(kind: kind, reason: record.reason.rawValue, exitCode: record.code))
            }
            self.counts = counts
            self.exits = exits
        }

        /// The kind a record counts under, nil for one that is not counted. Each helper process ends once in the
        /// child monitor's records (they carry the pid), so a renderer counts once per process, as Chrome's
        /// `NoRendererCrashesAssertion` counts `RenderProcessHostObserver::RenderProcessExited`: two tabs of one
        /// renderer are one exit, and a spare or orphaned renderer with no tab still counts. CEF's per-tab record
        /// only names the tab.
        static func countedKind(source: BrowserCrashRecord.Source, processType: String) -> Kind? {
            source == .process ? kind(processType: processType) : nil
        }

        static func kind(processType: String) -> Kind {
            switch processType {
            case "renderer", "extension": .renderer
            case "gpu-process": .gpu
            // `CEFRuntime.hostEnded`'s record: the Chromium Host is Chromium's browser process.
            case "chromium-host": .browser
            default: .utility
            }
        }
    }

    /// `oracle-state`'s `childExits` (cmux-tui/spec/commands.md): the holder exits the owner counted.
    nonisolated struct DaemonStateRequest: DaemonRequest {
        typealias Response = Reply
        static let commandName: DaemonCommandName = "oracle-state"

        nonisolated struct Reply: Decodable, Sendable {
            /// Kind (`holder`) to count; nil from a daemon before task 188.
            var childExits: [String: Int]?
        }
    }

    public var facet: OracleFacet { .crashes }
    public let capture: OracleFacetCapture

    /// - Parameters:
    ///   - app: The app's exits, read on the main actor; nil when the app's services are gone.
    ///   - daemon: The daemon's child exits by kind; nil while it is not connected or when its build has no
    ///     `oracle-state` (a release daemon).
    public init(app: @escaping @MainActor @Sendable () -> AppExits?,
                daemon: @escaping @MainActor @Sendable () async throws(OracleFacetError) -> [String: Int]?) {
        capture = .background { () async throws(OracleFacetError) -> OracleValue in
            guard let seen = await app() else {
                return .notComparable(reason: "the app's services are gone", task: OracleFacet.crashes.task)
            }
            guard let logged = try await daemon() else {
                return .notComparable(reason: "the daemon is not connected, or has no oracle-state childExits (a release or older daemon)",
                                      task: OracleFacet.crashes.task)
            }
            return Self.value(app: seen, daemon: logged)
        }
    }

    /// The facet's object: every kind's total, and the exits the app saw with their reasons.
    static func value(app: AppExits, daemon: [String: Int]) -> OracleValue {
        var counts: [String: OracleValue] = [:]
        for kind in Kind.allCases {
            counts[kind.rawValue] = OracleValue((app.counts[kind] ?? 0) + (daemon[kind.rawValue] ?? 0))
        }
        return ["counts": .object(counts), "exits": .array(app.exits.map(\.value))]
    }

    /// The daemon's child exits over `connection`, with the owner ends the connection counted as `daemon`. No
    /// connection, a lost one (a reconnect after a kill step: the dropped connection stays set until it is shut
    /// down) or a daemon that does not know `oracle-state` gives nil; a protocol or decode failure fails the
    /// snapshot, so an unread count is never taken for zero.
    public static func daemonChildExits(_ connection: DaemonConnection?) async throws(OracleFacetError) -> [String: Int]? {
        guard let connection else { return nil }
        do {
            guard var exits = try await connection.request(DaemonStateRequest()).childExits else { return nil }
            exits[Kind.daemon.rawValue] = await connection.droppedWithoutShutdown
            return exits
        } catch let error as DaemonError where error.isLostConnection {
            return nil
        } catch DaemonError.command(_, let message, _, _, _) where message.contains("unknown variant") {
            return nil
        } catch {
            throw OracleFacetError("oracle-state failed: \(error)")
        }
    }
}
#endif
