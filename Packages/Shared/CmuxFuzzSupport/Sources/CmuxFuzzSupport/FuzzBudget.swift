import Foundation

/// A time budget that scales with the input: `perUnit` for each `unitBytes` of
/// input, never less than one unit. An input over budget is a failure of the run, as a slow unit is
/// for libFuzzer (`-timeout`, `-report_slow_units`; testing/libfuzzer/README.md in Chromium), which
/// does not retry a slow unit either.
///
/// An input is timed `attempts` times and every attempt must be within the limit: the slowest one
/// decides, so a cold first render counts. The body gets the attempt's index; it must not reuse work
/// an earlier attempt (or input) cached, so each attempt costs what a first render costs.
public struct FuzzBudget: Sendable, Equatable {
    public var perUnit: Duration
    public var unitBytes: Int
    public var attempts: Int

    public init(perUnit: Duration, unitBytes: Int, attempts: Int = 3) {
        self.perUnit = perUnit
        self.unitBytes = max(unitBytes, 1)
        self.attempts = max(attempts, 1)
    }

    /// The limit for an input of `bytes` bytes.
    public func limit(bytes: Int) -> Duration {
        perUnit * max(1, Double(bytes) / Double(unitBytes))
    }

    /// The times of `attempts` runs of an input.
    public struct Timings: Sendable, Equatable {
        /// Sorted, fastest first; never empty.
        public var sorted: [Duration]

        public init(_ times: [Duration]) {
            sorted = times.isEmpty ? [.zero] : times.sorted()
        }

        /// The nearest-rank `p` quantile (0...1).
        public func quantile(_ p: Double) -> Duration {
            let rank = Int((min(max(p, 0), 1) * Double(sorted.count)).rounded(.up))
            return sorted[min(max(rank, 1), sorted.count) - 1]
        }

        public var p50: Duration { quantile(0.5) }
        public var p95: Duration { quantile(0.95) }
        public var slowest: Duration { sorted[sorted.count - 1] }

        /// `p50 12.0 ms, p95 14.1 ms, max 14.1 ms over 3 attempts`.
        public var summary: String {
            "p50 \(FuzzBudget.milliseconds(p50)) ms, p95 \(FuzzBudget.milliseconds(p95)) ms, "
                + "max \(FuzzBudget.milliseconds(slowest)) ms over \(sorted.count) attempts"
        }
    }

    /// Times `body` (given the attempt's index) `attempts` times; throws `FuzzError.property` naming
    /// `what` and the distribution when the slowest attempt is over the limit for `bytes`.
    @discardableResult
    public func check(
        _ what: @autoclosure () -> String, bytes: Int, fileID: String = #fileID, line: Int = #line,
        _ body: (Int) throws -> Void
    ) throws -> Timings {
        let allowed = self.limit(bytes: bytes)
        let clock = ContinuousClock()
        var times: [Duration] = []
        times.reserveCapacity(attempts)
        for attempt in 0..<attempts {
            let start = clock.now
            try body(attempt)
            times.append(clock.now - start)
        }
        let timings = Timings(times)
        try FuzzRun.check(timings.slowest <= allowed, "\(what()): \(bytes) bytes took \(timings.summary), "
            + "budget \(Self.milliseconds(allowed)) ms each", fileID: fileID, line: line)
        return timings
    }

    /// Milliseconds with one decimal, for messages.
    public static func milliseconds(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return String(format: "%.1f", ms)
    }
}
