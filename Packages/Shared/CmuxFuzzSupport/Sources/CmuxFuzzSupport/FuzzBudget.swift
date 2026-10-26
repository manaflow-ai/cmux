import Foundation

/// A time budget that scales with the input (p10-stability-028): `perUnit` for each `unitBytes` of
/// input, never less than one unit. An input over budget is a failure of the run, as a slow unit is
/// for libFuzzer (`-timeout`, `-report_slow_units`; testing/libfuzzer/README.md in Chromium).
///
/// An input is timed up to `attempts` times and its best time counts, so one preempted attempt on a
/// loaded machine does not fail it; the body must not hit a cache an earlier attempt filled (each
/// attempt gets its index to vary what it renders).
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

    /// Times `body` (given the attempt's index) until an attempt ends within the limit for `bytes`
    /// or `attempts` have run; throws `FuzzError.property` naming `what` when none did. Returns the
    /// time of the attempt within the limit.
    @discardableResult
    public func check(
        _ what: @autoclosure () -> String, bytes: Int, fileID: String = #fileID, line: Int = #line,
        _ body: (Int) throws -> Void
    ) throws -> Duration {
        let allowed = self.limit(bytes: bytes)
        let clock = ContinuousClock()
        var best: Duration?
        for attempt in 0..<attempts {
            let start = clock.now
            try body(attempt)
            let took = clock.now - start
            if took <= allowed { return took }
            best = min(best ?? took, took)
        }
        let fastest = best ?? allowed
        try FuzzRun.check(false, "\(what()): \(bytes) bytes took \(Self.milliseconds(fastest)) ms at best of \(attempts), "
            + "budget \(Self.milliseconds(allowed)) ms", fileID: fileID, line: line)
        return fastest
    }

    /// Milliseconds with one decimal, for messages.
    public static func milliseconds(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return String(format: "%.1f", ms)
    }
}
