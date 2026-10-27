public import CmuxNextMetrics
public import Darwin

extension ChromiumHelperProcess.Kind {
    /// The process kind the resource histograms name this helper by (`memory.<kind>_kib`, `cpu.<kind>_pct`, task 121):
    /// every renderer is a renderer, the network service is a utility process; nil for a helper of no listed type
    /// (crashpad, a zygote).
    public var resourceKind: HistogramID.ProcessKind? {
        switch self {
        case .renderer, .extensionRenderer: .renderer
        case .gpu: .gpu
        case .network, .utility: .utility
        case .other: nil
        }
    }
}

extension ChromiumHelperProcess {
    /// The app's live Chromium helpers as the processes of a resource sample, by type (``list(parent:)``: the app's
    /// own children, classified by their argv, never a name scan). Blocking system calls: call it off the main thread.
    public static func resourceProcesses(parent: pid_t = getpid()) -> [ProcessResourceSampler.KnownProcess] {
        list(parent: parent).compactMap { helper in helper.kind.resourceKind.map { .init(kind: $0, pid: helper.pid) } }
    }
}
