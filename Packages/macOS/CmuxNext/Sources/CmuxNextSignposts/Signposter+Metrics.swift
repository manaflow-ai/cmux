public import CmuxNextMetrics

extension Signposter {
    /// The field histograms of the process whose trace ring takes this signposter's records, so an emitter that
    /// holds a signposter records its samples into the same process's metrics file (the `cef.pump` pass, task 060).
    public var metrics: Metrics { Metrics(runtime: trace) }
}
