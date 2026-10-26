import CmuxNextMetrics
import Darwin

/// Records abnormal Chromium helper exits into the `cef.helper_exit` field histogram (``HistogramID/cefHelperExit``):
/// one enumeration sample per process that ended, its value the process type times 16 plus the reason
/// (``sample(_:_:)``). Chrome counts child process crashes and kills by process type the same way
/// (components/metrics/stability_metrics_helper.cc, `BrowserChildProcessCrashed` and `LogRendererCrash`).
/// The codes are part of the histogram and never change once shipped; a new type or reason takes a new code.
///
/// Page renderers count from Chromium's termination status in both roles, once per process (``CEFRendererEnd``),
/// as Chrome's `RenderProcessExited` does; the child monitor counts the other helpers, which no tab hears about.
///
/// ```swift
/// CEFHelperExitMetric(metrics: Metrics(runtime: runtime)).record(.gpu, .crashed) // sample 49
/// ```
nonisolated struct CEFHelperExitMetric: Sendable {
    /// The helper's kind, the high nibble of a sample.
    enum ProcessType: Int64, Sendable, CaseIterable {
        /// A type this list does not name (a new Chromium helper).
        case other = 0
        /// A page renderer (`--type=renderer`).
        case renderer = 1
        /// An extension renderer (`--type=renderer --extension-process`).
        case extensionRenderer = 2
        /// The GPU process (`--type=gpu-process`).
        case gpu = 3
        /// A utility process, the network service among them (`--type=utility`).
        case utility = 4

        /// The kind of a helper whose Chromium `--type=` value is `processType`.
        init(processType: String, isExtension: Bool) {
            switch processType {
            case "renderer": self = isExtension ? .extensionRenderer : .renderer
            case "gpu-process": self = .gpu
            case "utility": self = .utility
            default: self = .other
            }
        }
    }

    /// Where the samples go: the process's metrics file (tests pass a recorder on their own trace runtime).
    let metrics: Metrics

    init(metrics: Metrics = Metrics()) {
        self.metrics = metrics
    }

    /// One exit of a `type` helper that ended for `reason`.
    func record(_ type: ProcessType, _ reason: BrowserProcessExit.Reason) {
        metrics.record(.cefHelperExit, Self.sample(type, reason))
    }

    /// The histogram value: `type` times 16 plus the reason's code (1 to 6), below the layout's 256 values.
    static func sample(_ type: ProcessType, _ reason: BrowserProcessExit.Reason) -> Int64 {
        type.rawValue * 16 + reasonCode(reason)
    }

    /// The low nibble of a sample: fixed and nonzero, so a 0 nibble is no reason.
    static func reasonCode(_ reason: BrowserProcessExit.Reason) -> Int64 {
        switch reason {
        case .crashed: 1
        case .killed: 2
        case .outOfMemory: 3
        case .launchFailed: 4
        case .integrityFailure: 5
        case .abnormal: 6
        }
    }
}

/// Which browser reports a renderer process's end: RENDER_TERMINATED's `request` (the shim's renderer_end.h).
/// Same-site tabs can share one renderer, and Chromium tells each browser it hosted in one task
/// (RenderProcessHostImpl::ProcessDied); the first counts the end, the others share it.
nonisolated enum CEFRendererEnd: Int32, Sendable {
    /// The shim could not name the process (no main frame): the end counts for this browser.
    case unknown = 0
    /// The first browser of this process's end.
    case first = 1
    /// Another browser of an end already reported.
    case shared = 2
}

extension CEFChildProcessMonitor.Exit {
    /// Nil for a normal end (exit 0, or SIGTERM, which Chromium sends to
    /// helpers it no longer needs); otherwise why the helper ended.
    nonisolated var abnormalReason: BrowserProcessExit.Reason? {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff == 0 ? nil : .abnormal
        }
        if signal == 0x7f { return nil }  // stopped, not ended
        switch signal {
        case SIGTERM: return nil
        case SIGKILL: return .killed
        default: return .crashed
        }
    }
}
