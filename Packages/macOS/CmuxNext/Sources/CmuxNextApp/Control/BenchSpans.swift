import CmuxNextLayout
import Foundation

/// Main-thread spans for `debug.new_tab` benches (never-merge instrument branch: doc shortened).
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

    static func begin() {
        #if DEBUG || CMUX_BENCH_HOOKS
        origin = .now
        Thread.main.threadDictionary["cmux.benchMeasure"] = { (name: String, body: () -> Void) in measure(name, body) } as (String, () -> Void) -> Void
        spans.removeAll(keepingCapacity: true); if let origin { BenchTurnRecorder.main().start(origin) }
        #endif
    }

    static func end() -> [Span] {
        #if DEBUG || CMUX_BENCH_HOOKS
        origin = nil; let turns = BenchTurnRecorder.main().stop().map { Span(name: $0.name, start: $0.start, milliseconds: $0.milliseconds) }
        return spans + turns
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

    /// Records an instant under `name`, or a span another module timed that is `milliseconds` long and ends now.
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
