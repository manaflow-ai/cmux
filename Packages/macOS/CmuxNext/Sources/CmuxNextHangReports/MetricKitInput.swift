public import Foundation

/// What one MetricKit delivery gave, in neutral types (``MetricKitSubscriber`` makes it from the
/// `MX*` objects; tests write it by hand). Everything here is untrusted: ``HangReportBuilder``
/// keeps only what section 3 of hang-reports-DESIGN.md allows.
public nonisolated struct MetricKitInput: Sendable, Equatable {
    /// One `MXHangDiagnostic`.
    public struct Hang: Sendable, Equatable {
        /// How long it lasted, in milliseconds.
        public var durationMs: Int
        /// `callStackTree.jsonRepresentation()`.
        public var callStackTree: Data

        /// Makes the value from its parts.
        public init(durationMs: Int, callStackTree: Data) {
            self.durationMs = durationMs
            self.callStackTree = callStackTree
        }
    }

    /// One `MXCPUExceptionDiagnostic`.
    public struct CPUException: Sendable, Equatable {
        /// CPU time in milliseconds.
        public var cpuMs: Int
        /// The time MetricKit sampled, in milliseconds.
        public var sampledMs: Int
        /// `MXCallStackTree.jsonRepresentation()` (untrusted).
        public var callStackTree: Data

        /// Makes the value from its parts.
        public init(cpuMs: Int, sampledMs: Int, callStackTree: Data) {
            self.cpuMs = cpuMs
            self.sampledMs = sampledMs
            self.callStackTree = callStackTree
        }
    }

    /// One `MXSignpostMetric`.
    public struct Signpost: Sendable, Equatable {
        /// The signpost category (untrusted).
        public var category: String
        /// The signpost name (untrusted).
        public var name: String
        /// How many values fell in it.
        public var count: Int
        /// The duration histogram.
        public var buckets: [HistogramBucket]
        /// Hitch milliseconds per second, when given.
        public var hitchMsPerS: Double?

        /// Makes the value from its parts.
        public init(category: String, name: String, count: Int, buckets: [HistogramBucket], hitchMsPerS: Double? = nil) {
            self.category = category
            self.name = name
            self.count = count
            self.buckets = buckets
            self.hitchMsPerS = hitchMsPerS
        }
    }

    /// Hang diagnostics.
    public var hangs: [Hang] = []
    /// MetricKit CPU exceptions, heaviest first.
    public var cpuExceptions: [CPUException] = []
    /// MetricKit's aggregated metrics.
    public var metrics = HangReport.Metrics()
    /// Signpost metrics.
    public var signposts: [Signpost] = []

    /// Makes the value from its parts.
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
