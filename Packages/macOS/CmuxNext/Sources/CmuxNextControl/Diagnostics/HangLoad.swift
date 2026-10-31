/// What the main thread and the process did during a hang, so its file tells a busy main
/// thread (its own work) from a blocked one (page-ins, WindowServer, a lock, another process).
public struct HangLoad: Sendable, Equatable {
    /// CPU the main thread used since the stall began; nil when it could not be read.
    public var mainThreadCPU: Duration?
    /// The process's page-ins (reads from disk or swap) since the watchdog first sampled the
    /// stall; nil when unknown.
    public var pageIns: UInt64?
    /// The process's page faults over the same span; nil when unknown.
    public var faults: UInt64?

    /// - Parameters:
    ///   - mainThreadCPU: CPU the main thread used since the stall began.
    ///   - pageIns: The process's page-ins since the stall's first sample.
    ///   - faults: The process's page faults since the stall's first sample.
    public init(mainThreadCPU: Duration? = nil, pageIns: UInt64? = nil, faults: UInt64? = nil) {
        self.mainThreadCPU = mainThreadCPU
        self.pageIns = pageIns
        self.faults = faults
    }
}
