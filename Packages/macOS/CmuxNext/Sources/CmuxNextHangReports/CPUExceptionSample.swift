/// One `MXCPUExceptionDiagnostic`: the CPU time that went over the system's limit and the
/// heaviest stack of the samples.
public nonisolated struct CPUExceptionSample: Codable, Sendable, Equatable {
    /// CPU time in milliseconds.
    public var cpuMs: Int
    /// The time MetricKit sampled, in milliseconds.
    public var sampledMs: Int
    /// Innermost first, at most ``HangSample/maxFrames``.
    public var frames: [HangReportFrame]

    /// Makes the value from its parts.
    public init(cpuMs: Int, sampledMs: Int, frames: [HangReportFrame]) {
        self.cpuMs = max(0, cpuMs)
        self.sampledMs = max(0, sampledMs)
        self.frames = Array(frames.prefix(HangSample.maxFrames))
    }
}
