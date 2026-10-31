import Foundation

/// Main-thread spans for `debug.new_tab` benches (R81: Cmd-W and `!` on the
/// new tab page in < 10 ms). DEBUG builds record into a bounded ring while a
/// bench runs; release builds run the body and record nothing.
@MainActor
enum BenchSpans {
    struct Span {
        var name: String
        /// Milliseconds since the bench started.
        var start: Double
        var milliseconds: Double
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    private static var origin: ContinuousClock.Instant?
    private(set) static var spans: [Span] = []
    static let capacity = 512
    #endif

    /// Starts recording (a bench began).
    static func begin() {
        #if DEBUG || CMUX_BENCH_HOOKS
        origin = .now
        spans.removeAll(keepingCapacity: true)
        #endif
    }

    /// Stops recording and returns what was recorded.
    static func end() -> [Span] {
        #if DEBUG || CMUX_BENCH_HOOKS
        origin = nil
        return spans
        #else
        return []
        #endif
    }

    /// Runs `body`, recording its main-thread time under `name` while a bench runs.
    static func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard let origin else { return try body() }
        let start = ContinuousClock.now
        defer {
            if spans.count < capacity {
                spans.append(Span(name: name, start: Self.ms(start - origin), milliseconds: Self.ms(.now - start)))
            }
        }
        #endif
        return try body()
    }

    /// Records an instant (a point in an async flow) under `name`, or a span another module timed
    /// (`CEFBenchMarks`) that is `milliseconds` long and ends now.
    static func mark(_ name: String, milliseconds: Double = 0) {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard let origin, spans.count < capacity else { return }
        spans.append(Span(name: name, start: Self.ms(.now - origin) - milliseconds, milliseconds: milliseconds))
        #endif
    }

    nonisolated static func ms(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
