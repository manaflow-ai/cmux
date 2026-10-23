/// One `MXCPUExceptionDiagnostic`: the CPU time that went over the system's limit and the
/// heaviest stack of the samples.
public nonisolated struct CPUExceptionSample: Codable, Sendable, Equatable {
    public var cpuMs: Int
    public var sampledMs: Int
    /// Innermost first, at most ``HangSample/maxFrames``.
    public var frames: [HangReportFrame]

    public init(cpuMs: Int, sampledMs: Int, frames: [HangReportFrame]) {
        self.cpuMs = max(0, cpuMs)
        self.sampledMs = max(0, sampledMs)
        self.frames = Array(frames.prefix(HangSample.maxFrames))
    }
}
