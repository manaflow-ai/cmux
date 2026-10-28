import CmuxNextMetrics

/// The `stability.child_exit` count of a Chromium helper (p09-observability-109), in the same store as its
/// `cef.helper_exit` sample: one sample of its process kind per abnormal end the child monitor sees, valued by its
/// wait status (``HistogramID/ChildExit/init(waitStatus:outOfMemory:)``); only the monitor has a page renderer's
/// status. Chrome counts a child process crash by process type in `Stability.Counts2`
/// (components/metrics/stability_metrics_helper.cc, `BrowserChildProcessCrashed`).
extension CEFHelperExitMetric {
    /// Counts the abnormal end `exit` and returns the helper's type; a type the stability counts do not name
    /// (``ProcessType/stabilityKind``) counts nothing.
    @discardableResult
    func childExited(_ exit: CEFChildProcessMonitor.Exit) -> ProcessType {
        let type = ProcessType(processType: exit.processType, isExtension: exit.isExtension)
        if let kind = type.stabilityKind {
            let ended = HistogramID.ChildExit(waitStatus: exit.status, outOfMemory: exit.outOfMemory)
            StabilityCounters(metrics: metrics).childExited(kind, ended)
        }
        return type
    }
}

extension CEFHelperExitMetric.ProcessType {
    /// The helper's process kind in `stability.child_exit`; nil for a type that list does not name.
    var stabilityKind: HistogramID.ProcessKind? {
        switch self {
        case .renderer, .extensionRenderer: .renderer
        case .gpu: .gpu
        case .utility: .utility
        case .other: nil
        }
    }
}
