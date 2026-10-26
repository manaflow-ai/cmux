#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextBrowser
public import CmuxNextDaemon
public import CmuxNextOracle

/// The oracle's `crashes` facet (p15-oracle-188, schemas/oracle/snapshot-v1.schema.json `crashes`): the child
/// process exits of this app and its daemon, by kind, as totals the runner diffs between checkpoints. Invariant I17
/// fails a case on an exit no `allow_crashes` entry of the case covers.
///
/// Chromium fails a browser test on any renderer crash it did not allow (`NoRendererCrashesAssertion` and
/// `ScopedAllowRendererCrashes`, content/public/test/browser_test_base.h). The sources are the records the app and
/// the daemon already keep, read only when a snapshot asks:
/// - renderer, gpu, utility: Chromium's crash log (`CEFRuntime+Crashes`): the per-tab record of CEF's
///   `OnRenderProcessTerminated` and the helper exits `CEFChildProcessMonitor` sees.
/// - browser: the App's `CrashRecoveryService`: this launch follows a run that ended unexpectedly, whose process
///   held Chromium's browser process.
/// - holder, daemon: the daemon's `oracle-state` `childExits`, from its terminal loss log.
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

    /// The exits the app saw itself, oldest first: the previous run's end, then Chromium's log.
    public nonisolated struct AppExits: Sendable, Hashable {
        public var exits: [Exit]

        public init(exits: [Exit]) {
            self.exits = exits
        }

        /// Nil when the crash log dropped records (it keeps ``BrowserCrashLog/capacity``), so a count would be short.
        /// - Parameters:
        ///   - previous: How the run this launch follows ended, when it ended unexpectedly.
        ///   - records: Chromium's crash log, oldest first; `total` is every record since launch.
        public init?(previous: PreviousEnd?, records: [BrowserCrashRecord], total: Int) {
            guard total == records.count else { return nil }
            var exits: [Exit] = []
            if let previous {
                let reason = previous.signal != nil ? "crashed" : previous.raisedException ? "exception" : "killed"
                exits.append(Exit(kind: .browser, reason: reason, exitCode: previous.signal.map { Int($0) }))
            }
            for record in records {
                guard let kind = Self.kind(of: record) else { continue }
                exits.append(Exit(kind: kind, reason: record.reason.rawValue, exitCode: record.code))
            }
            self.exits = exits
        }

        /// A renderer's end is counted once per tab it ended, from CEF's own record; the child monitor's record of
        /// the same process is skipped. An extension renderer has no tab, so its process record counts it.
        static func kind(of record: BrowserCrashRecord) -> Kind? {
            switch (record.source, record.processType) {
            case (.engine, _): .renderer
            case (.process, "renderer"): nil
            case (.process, "extension"): .renderer
            case (.process, "gpu-process"): .gpu
            case (.process, _): .utility
            }
        }
    }

    /// `oracle-state`'s `childExits` (cmux-tui/spec/commands.md): what the daemon's terminal loss log records.
    nonisolated struct DaemonStateRequest: DaemonRequest {
        typealias Response = Reply
        static let commandName: DaemonCommandName = "oracle-state"

        nonisolated struct Reply: Decodable, Sendable {
            /// Kind (`holder`, `daemon`) to count; nil from a daemon before task 188.
            var childExits: [String: Int]?
        }
    }

    public var facet: OracleFacet { .crashes }
    public let capture: OracleFacetCapture

    /// - Parameters:
    ///   - app: The app's exits, read on the main actor; nil when they cannot be counted exactly.
    ///   - daemon: The daemon's child exits by kind; nil while it is not connected or when its build has no
    ///     `oracle-state` (a release daemon).
    public init(app: @escaping @MainActor @Sendable () -> AppExits?,
                daemon: @escaping @MainActor @Sendable () async throws(OracleFacetError) -> [String: Int]?) {
        capture = .background { () async throws(OracleFacetError) -> OracleValue in
            guard let seen = await app() else {
                return .notComparable(reason: "Chromium's crash log dropped records, so its counts would be short",
                                      task: OracleFacet.crashes.task)
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
            let seen = app.exits.lazy.filter { $0.kind == kind }.count
            counts[kind.rawValue] = OracleValue(seen + (daemon[kind.rawValue] ?? 0))
        }
        return ["counts": .object(counts), "exits": .array(app.exits.map(\.value))]
    }

    /// The daemon's child exits over `connection`. No connection (a reconnect after a kill step) or a daemon that does
    /// not know `oracle-state` gives nil; any other failure fails the snapshot, so an unread count is never taken for zero.
    public static func daemonChildExits(_ connection: DaemonConnection?) async throws(OracleFacetError) -> [String: Int]? {
        guard let connection else { return nil }
        do {
            return try await connection.request(DaemonStateRequest()).childExits
        } catch DaemonError.command(_, let message, _, _, _) where message.contains("unknown variant") {
            return nil
        } catch {
            throw OracleFacetError("oracle-state failed: \(error)")
        }
    }
}
#endif
