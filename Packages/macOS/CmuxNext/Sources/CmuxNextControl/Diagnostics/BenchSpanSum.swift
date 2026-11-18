#if DEBUG || CMUX_BENCH_HOOKS
/// The spans of one bench window, for the number that a bench reply gives as `main_thread_spans_ms`
/// (`debug.new_tab bench_open` and `bench_create`).
///
/// A reply's span list holds each span of the bench's window. The sum is the number that a reader compares
/// between two builds, so a span that a later build adds for another reader must not change it: the spans of
/// the sidebar's work (each name that starts with `sidebar.`) are in the list and not in the sum.
public struct BenchSpanSum {
    private let spans: [(name: String, milliseconds: Double)]

    /// - Parameter spans: each span of one bench window, with its name and its time in milliseconds.
    public init(_ spans: [(name: String, milliseconds: Double)]) {
        self.spans = spans
    }

    /// The sum, in milliseconds, of the spans, without the spans of the sidebar's work.
    public var mainThread: Double {
        spans.reduce(0) { $1.name.hasPrefix("sidebar.") ? $0 : $0 + $1.milliseconds }
    }
}
#endif
