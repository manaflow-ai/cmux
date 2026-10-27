#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import CmuxNextMetrics
import Darwin

/// What cmux does when a Chromium Host process ends (plans/cmux-next/chrome-parity/p09-observability.md, task
/// 104 (d) and (e)), in host mode (`CEFRuntime.hostEnded`, from ``ChromiumHostExitReporting/onHostEnded``) and in
/// the `debug.chromium_host` prototype (`ChromiumHostSession`):
///
/// - every end it hears counts in `stability.child_exit.chromium_host` by how the host ended;
/// - an end by itself (a crash, a kill) is one ``ChromiumHostEndReport`` with the host's black box and crash keys,
///   when ``ChromiumHostEndReportLimit`` lets it through; ``send`` (the App) uploads it;
/// - every end deletes the host's recording ring and metrics file (``forget(pid:)``: the session at each end, the
///   host mode's `CEFHostStart` from its supervisor's end observers), which only a live host writes and nothing
///   folds; its black box and crash keys stay for the report and `TraceRingCleanup`.
///
/// Chrome's browser handles a child's end in one observer the same way: it counts the end, reports a crash with
/// the child's crash keys and forgets the child's files (`ChildExitObserver`,
/// components/crash/content/browser/child_exit_observer_android.cc). Main thread; file work goes to ``postFiles``.
@MainActor
public final class ChromiumHostEndReports {
    /// Takes a report to upload (the App: reads its files off main, then Sentry).
    public typealias Send = @MainActor (ChromiumHostEndReport) -> Void
    /// Runs blocking file work off the main thread (BackgroundWork `.files`).
    public typealias PostFiles = @Sendable (@escaping @Sendable () -> Void) -> Void

    /// Where every host writes its trace files (``ChromiumHostTraceFiles/app(bundleID:)``); nil: nowhere.
    let traceFiles: ChromiumHostTraceFiles?
    private var limit: ChromiumHostEndReportLimit
    private let metrics: Metrics
    private let postFiles: PostFiles
    private let send: Send
    /// Hosts that ended by themselves so far: the restart count of the next report.
    private(set) var crashes = 0

    /// The App's: the process's metrics and the standard hourly limit.
    public convenience init(traceFiles: ChromiumHostTraceFiles?, postFiles: @escaping PostFiles, send: @escaping Send) {
        self.init(traceFiles: traceFiles, limit: ChromiumHostEndReportLimit(), metrics: Metrics(), postFiles: postFiles, send: send)
    }

    init(traceFiles: ChromiumHostTraceFiles?, limit: ChromiumHostEndReportLimit, metrics: Metrics,
         postFiles: @escaping PostFiles, send: @escaping Send) {
        self.traceFiles = traceFiles
        self.limit = limit
        self.metrics = metrics
        self.postFiles = postFiles
        self.send = send
    }

    /// Host `pid` ended: `exit` is how (nil for a clean exit, status 0). Counts it, and when it ended by itself
    /// (`byItself`: not a quit or an idle exit cmux asked for) and the limit allows, sends its report with
    /// `budget`. The caller forgets the host's files (``forget(pid:)``) at every end, this one included.
    func hostEnded(pid: Int32, exit: BrowserProcessExit?, byItself: Bool, budget: ChromiumHostEndReport.Budget? = nil) {
        metrics.record(.stabilityChildExit(.chromiumHost), (exit?.stabilityExit ?? .clean).rawValue)
        guard let exit, byItself else { return }
        let restarts = crashes
        crashes += 1
        let report = ChromiumHostEndReport(pid: pid, exit: exit, restarts: restarts, budget: budget,
                                           blackBoxPath: traceFiles?.blackBoxPath(pid: pid),
                                           crashKeysPath: traceFiles?.crashKeysPath(pid: pid))
        guard limit.allows(report.exitDescription) else { return }
        send(report)
    }

    /// Deletes host `pid`'s recording ring and metrics file off the main thread: the host is gone, so nothing
    /// writes them again, and a host started after it gets a new pid and new files.
    func forget(pid: Int32) {
        guard pid > 0, let traceFiles else { return }
        let paths = traceFiles.liveOnlyPaths(pid: pid)
        postFiles {
            for path in paths { _ = blockingCall(.fileIO) { unlink(path) } }
        }
    }
}
#endif
