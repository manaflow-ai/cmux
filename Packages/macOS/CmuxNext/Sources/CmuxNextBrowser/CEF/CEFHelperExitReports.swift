import CmuxNextWakeups
import Foundation

/// A runtime's helper-exit reports: each Chromium helper process's one abnormal end goes to
/// ``BrowserCrashLog/helperExited(_:)`` (the App's Sentry event) with its pid, the pid the `.ips` file and the
/// minidump of the same process carry.
///
/// A page renderer's end is reported twice, and its report needs both: Chromium's termination status
/// (RENDER_TERMINATED) has the reason, the child monitor's exit has the pid. Both name the renderer's client id
/// (its `--renderer-client-id`, the render process host id), as Chrome keys a renderer's exit by that host id
/// (content/browser/renderer_host/render_process_host_impl.cc, ProcessDied). The report that comes first waits at
/// most ``wait`` for the other; Chromium's status then goes alone, with no pid.
@MainActor
final class CEFHelperExitReports {
    /// One report of a page renderer's end.
    enum Half {
        /// Chromium's status of the end (the first browser the renderer hosted) and the pump's state then.
        case chromium(BrowserProcessExit, pump: [String: String])
        /// The child monitor's exit of the process.
        case monitor(pid: Int32)
    }

    /// How long a renderer's report waits for the other. Both come within milliseconds of the process's end; a
    /// renderer that never ran (a launch failure) or that hosted no page has only one.
    static let wait: Duration = .seconds(2)

    private let crashLog: BrowserCrashLog
    private var waiting: [Int32: (half: Half, wait: AlignedWakeups.Ticket)] = [:]

    init(crashLog: BrowserCrashLog) {
        self.crashLog = crashLog
    }

    /// Renderer ends waiting for their other report.
    var waitingCount: Int { waiting.count }

    /// A helper only the monitor reports (GPU, utility, extension renderer, other): its report now.
    func helperEnded(_ kind: CEFHelperExitMetric.ProcessType, _ exit: CEFChildProcessMonitor.Exit,
                     reason: BrowserProcessExit.Reason, pump: [String: String]) {
        crashLog.helperExited(BrowserHelperExit(processType: kind.reportName, chromiumType: exit.processType,
                                                subType: exit.subType, pid: exit.pid, reason: reason,
                                                code: Int(exit.status), pump: pump))
    }

    /// Chromium's status of a page renderer's end. It waits for the monitor's exit of renderer `client` when
    /// `joinable` (the monitor watches the renderers: not in host mode, where they are the host's children);
    /// with no client id (the shim could not name the renderer) or nothing to join, it goes now with no pid.
    func rendererEnded(_ exit: BrowserProcessExit, client: Int32, joinable: Bool, pump: [String: String],
                       deadlines: AlignedWakeups) {
        guard client > 0, joinable else { return rendererReport(exit, pump: pump, pid: nil) }
        arrived(.chromium(exit, pump: pump), client: client, deadlines: deadlines)
    }

    /// The monitor's abnormal exit of a page renderer.
    func rendererProcessEnded(_ exit: CEFChildProcessMonitor.Exit, deadlines: AlignedWakeups) {
        guard let client = exit.rendererClientID, client > 0 else { return }
        arrived(.monitor(pid: exit.pid), client: client, deadlines: deadlines)
    }

    /// The message pump's numbers since CefInitialize (``CEFPumpStats``), or in host mode, where the Chromium host
    /// runs the pump and keeps its numbers (p09-observability task 104), only the mode.
    static func pumpState(hostMode: Bool, stats: CEFPumpStats?) -> [String: String] {
        if hostMode { return ["mode": "host"] }
        guard let stats else { return ["mode": "none"] }
        return [
            "mode": "in_process",
            "work_runs": String(stats.workRuns),
            "long_work_runs": String(stats.longWorkRuns),
            "pass_p99_ms": String(format: "%.1f", stats.passMillisecondsP99),
        ]
    }

    private func arrived(_ half: Half, client: Int32, deadlines: AlignedWakeups) {
        if let held = waiting.removeValue(forKey: client) {
            _ = deadlines.cancel(held.wait)
            switch (held.half, half) {
            case (.chromium(let exit, let pump), .monitor(let pid)), (.monitor(let pid), .chromium(let exit, let pump)):
                return rendererReport(exit, pump: pump, pid: pid)
            case (.chromium, .chromium), (.monitor, .monitor):
                waitRanOut(held.half) // an earlier end of a relaunched renderer host: it goes as it is
            }
        }
        let wait = deadlines.schedule(owner: "CEFRuntime.rendererEnd", after: Self.wait) { [weak self] in
            guard let self, let held = waiting.removeValue(forKey: client) else { return }
            waitRanOut(held.half)
        }
        waiting[client] = (half, wait)
    }

    /// A report whose other never came: Chromium's status goes with no pid; the monitor's alone is a renderer
    /// Chromium reported no page end for, which the crash log keeps.
    private func waitRanOut(_ half: Half) {
        if case .chromium(let exit, let pump) = half { rendererReport(exit, pump: pump, pid: nil) }
    }

    private func rendererReport(_ exit: BrowserProcessExit, pump: [String: String], pid: Int32?) {
        crashLog.helperExited(BrowserHelperExit(processType: CEFHelperExitMetric.ProcessType.renderer.reportName,
                                                chromiumType: "renderer", pid: pid, reason: exit.reason,
                                                code: exit.code, pump: pump))
    }
}

private extension CEFHelperExitMetric.ProcessType {
    /// ``BrowserHelperExit/processType``: a fixed name per kind.
    var reportName: String {
        switch self {
        case .other: "other"
        case .renderer: "renderer"
        case .extensionRenderer: "extension"
        case .gpu: "gpu"
        case .utility: "utility"
        }
    }
}
