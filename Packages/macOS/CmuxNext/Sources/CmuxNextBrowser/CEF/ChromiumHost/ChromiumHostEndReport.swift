#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import CmuxNextMetrics
import CmuxNextTrace
import Foundation

/// A Chromium host that ended by itself (a signal or an exit status cmux did not ask for), as the crash
/// report of its end carries it (plans/cmux-next/chrome-parity/p09-observability.md, task 104 (d)): how it
/// ended, how often the session restarted it and what the restart budget decided, and where its black box and
/// crash keys are. cmux keeps running; only the host ended. Chrome's browser reports a child's crash the same
/// way, from the outside, with the child's own crash keys (`ChildExitObserver`,
/// components/crash/content/browser/child_exit_observer_android.cc; crashpad's handler reads the dead
/// process's annotations).
///
/// ``ChromiumHostSession`` makes one per end that passes ``ChromiumHostEndReportLimit``; the App sends it.
public nonisolated struct ChromiumHostEndReport: Sendable, Equatable {
    /// The host's pid.
    public var pid: Int32
    /// The signal that ended it, nil for an exit.
    public var signal: Int32?
    /// Its exit status, nil for a signal.
    public var status: Int32?
    /// Hosts the session started again after a crash so far.
    public var restarts: Int
    /// Crashes the restart budget has not forgiven yet (`ChromiumHostRestartPolicy.recentCrashes`).
    public var recentCrashes: Int
    /// What the budget decided: `restart`, `ended` or `cannot_start`.
    public var decision: String
    /// The host said `ready` (its Chromium started) before it ended.
    public var saidHello: Bool
    /// Its black box and crash-key page; nil when the host had no trace folder.
    public var blackBoxPath: String?
    public var crashKeysPath: String?

    /// `signal 11`, `exit 68`.
    public var exitDescription: String {
        ChromiumHostExit(signal: signal, status: status).description
    }

    /// The event's parts, read from the host's files.
    public struct Details: Sendable, Equatable {
        public var message: String
        public var type: String
        /// One issue per way of ending (`signal 11`, `exit 68`).
        public var fingerprint: [String]
        /// `chromium_host.exit`, `chromium_host.decision` and the host's crash keys (`crash_key.<name>`).
        public var tags: [String: String]
        /// The restart count, recent crashes, pid and, with the hang-reports opt-in, `blackbox_tail`: the host's
        /// newest black-box records that may leave the Mac (``TraceBlackBoxUpload``: catalog names and numbers
        /// only, no flow and no per-input record).
        public var extra: [String: String]
    }

    /// The most black-box lines ``Details/extra`` carries.
    public static let tailLines = 64

    /// The event's parts, with the host's crash keys and, when `hangReportsOptIn`, its black-box tail. Reads both
    /// files: call it off the main thread (BackgroundWork `.files`).
    public func details(hangReportsOptIn: Bool) -> Details {
        var tags = ["chromium_host.exit": exitDescription, "chromium_host.decision": decision]
        if let crashKeysPath, let page = CrashKeyPage.read(atPath: crashKeysPath),
           page.identity.role == .chromiumHost, page.identity.pid == UInt32(bitPattern: pid) {
            tags.merge(page.tags) { current, _ in current }
        }
        var extra = ["restarts": String(restarts), "recent_crashes": String(recentCrashes), "pid": String(pid),
                     "said_hello": saidHello ? "1" : "0"]
        if let tail = blackBoxTail(hangReportsOptIn: hangReportsOptIn) { extra["blackbox_tail"] = tail }
        return Details(message: "Chromium host ended (\(exitDescription))", type: "ChromiumHostExit",
                       fingerprint: ["chromium-host-exit", exitDescription], tags: tags, extra: extra)
    }

    /// The newest ``tailLines`` uploadable records of the host's black box, nil without the opt-in or a ring.
    func blackBoxTail(hangReportsOptIn: Bool) -> String? {
        guard hangReportsOptIn, let blackBoxPath else { return nil }
        let data = try? Data(blockingContentsOf: URL(fileURLWithPath: blackBoxPath), options: .mappedIfSafe)
        guard let bytes = data.map({ [UInt8]($0) }), let image = TraceRing.Image(bytes: bytes),
              image.header.pid == UInt32(bitPattern: pid) else { return nil }
        let upload = TraceBlackBoxUpload(limit: Self.tailLines)
        return upload.crashAttachmentText(TraceBlackBoxUpload.records(of: image), hangReportsOptIn: true)
    }
}

nonisolated extension ChromiumHostExit {
    /// The end as `stability.child_exit.chromium_host` counts it (task 109's dimensions): a status of 0 is clean,
    /// a signal or an unreadable end a signal, any other status a fatal error the host reported (a start failure,
    /// a bad message from cmux).
    var stabilityExit: HistogramID.ChildExit {
        if signal != nil || status == nil { return .signal }
        return status == 0 ? .clean : .panic
    }
}

/// One crash report per way a host ends (`signal 11`, `exit 68`) per ``interval``: a host that crashes on start
/// and is restarted within the budget does not send three events a minute. The stability counter still counts
/// every end. crashpad limits its uploads per hour the same way (`ShouldRateLimitUpload`,
/// handler/crash_report_upload_thread.cc). The clock is injected.
nonisolated struct ChromiumHostEndReportLimit: Sendable {
    static let standardInterval: Duration = .seconds(60 * 60)

    let interval: Duration
    /// When each way of ending last sent a report, as time since the limit was made.
    private var lastReport: [String: Duration] = [:]
    private let elapsed: @Sendable () -> Duration

    init() {
        self.init(clock: ContinuousClock())
    }

    init<C: Clock>(clock: C, interval: Duration = ChromiumHostEndReportLimit.standardInterval) where C.Duration == Duration {
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        self.interval = interval
    }

    /// Whether an end described as `exit` sends a report now; a yes starts its interval.
    mutating func allows(_ exit: String) -> Bool {
        let now = elapsed()
        if let last = lastReport[exit], now - last < interval { return false }
        lastReport[exit] = now
        return true
    }
}
#endif
