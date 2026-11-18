#if DEBUG || CMUX_BENCH_HOOKS
/// The number that a bench reply gives as `main_thread_spans_ms` (`debug.new_tab bench_open` and `bench_create`).
///
/// A reply's span list holds each span of the bench's window. This sum is the number that a reader compares
/// between two builds, so a span that a later build adds for another reader must not change it.
public enum BenchSpanSum {
    /// The sum, in milliseconds, of the spans of one bench window.
    public static func mainThread(_ spans: [(name: String, milliseconds: Double)]) -> Double {
        spans.reduce(0) { $0 + $1.milliseconds }
    }
}
#endif
