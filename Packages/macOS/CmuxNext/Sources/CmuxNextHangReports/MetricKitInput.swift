public import Foundation

/// What one MetricKit delivery gave, in neutral types (``MetricKitSubscriber`` makes it from the
/// `MX*` objects; tests write it by hand). Everything here is untrusted: ``HangReportBuilder``
/// keeps only what section 3 of hang-reports-DESIGN.md allows.
public nonisolated struct MetricKitInput: Sendable, Equatable {
    /// One `MXHangDiagnostic`.
    public struct Hang: Sendable, Equatable {
        public var durationMs: Int
        /// `callStackTree.jsonRepresentation()`.
        public var callStackTree: Data

        public init(durationMs: Int, callStackTree: Data) {
            self.durationMs = durationMs
            self.callStackTree = callStackTree
        }
    }

    /// One `MXCPUExceptionDiagnostic`.
    public struct CPUException: Sendable, Equatable {
        public var cpuMs: Int
        public var sampledMs: Int
        public var callStackTree: Data

        public init(cpuMs: Int, sampledMs: Int, callStackTree: Data) {
            self.cpuMs = cpuMs
            self.sampledMs = sampledMs
            self.callStackTree = callStackTree
        }
    }

    /// One `MXSignpostMetric`.
    public struct Signpost: Sendable, Equatable {
        public var category: String
        public var name: String
        public var count: Int
        public var buckets: [HistogramBucket]
        public var hitchMsPerS: Double?

        public init(category: String, name: String, count: Int, buckets: [HistogramBucket], hitchMsPerS: Double? = nil) {
            self.category = category
            self.name = name
            self.count = count
            self.buckets = buckets
            self.hitchMsPerS = hitchMsPerS
        }
    }

    public var hangs: [Hang] = []
    public var cpuExceptions: [CPUException] = []
    public var metrics = HangReport.Metrics()
    public var signposts: [Signpost] = []

    public init(hangs: [Hang] = [], cpuExceptions: [CPUException] = [], metrics: HangReport.Metrics = HangReport.Metrics(),
                signposts: [Signpost] = []) {
        self.hangs = hangs
        self.cpuExceptions = cpuExceptions
        self.metrics = metrics
        self.signposts = signposts
    }

    /// Whether the delivery held nothing a report uses.
    public var isEmpty: Bool { hangs.isEmpty && cpuExceptions.isEmpty && metrics.isEmpty && signposts.isEmpty }
}
