/// What one Chromium tracing step did (p09-observability task 051): the browser side (`CEFTracing`) fills it, and
/// the control socket's `trace.start` and `trace.stop` report it as their `chromium` member, which
/// `cmux trace record` reads (cmux-tui cli/trace/bundle.rs: `path` and `offset_ns`, or `reason`/`error`).
///
/// ```swift
/// let report = ChromiumTraceReport(state: .stopped, mode: "in_process", path: tracePath, offsetNanos: 7000)
/// ```
public nonisolated struct ChromiumTraceReport: Sendable, Equatable {
    /// Where the recording stands after the step.
    public enum State: String, Sendable {
        /// Chromium records.
        case recording
        /// Chromium wrote its JSON trace.
        case stopped
        /// This Chromium cannot trace (``detail`` says why).
        case untraced
        /// The step failed (``error`` names how).
        case error
    }

    public var state: State
    /// The process that traced: `in_process` or `host`.
    public var mode: String?
    /// The category filter Chromium records.
    public var categories: String?
    /// The JSON trace.
    public var path: String?
    /// The meta.json beside it, with the clock offset.
    public var metaPath: String?
    /// Added to a Chromium timestamp (ns) to put it on the local trace clock; nil when Chromium's clock was not read.
    public var offsetNanos: Int64?
    /// How far ``offsetNanos`` may be off.
    public var errorBoundNanos: Int64?
    /// The failure's code.
    public var error: String?
    /// Why this Chromium cannot trace.
    public var detail: String?

    public init(state: State, mode: String? = nil, categories: String? = nil, path: String? = nil, metaPath: String? = nil,
                offsetNanos: Int64? = nil, errorBoundNanos: Int64? = nil, error: String? = nil, detail: String? = nil) {
        self.state = state
        self.mode = mode
        self.categories = categories
        self.path = path
        self.metaPath = metaPath
        self.offsetNanos = offsetNanos
        self.errorBoundNanos = errorBoundNanos
        self.error = error
        self.detail = detail
    }
}
