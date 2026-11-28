import Foundation

/// SplitMix64: small, fast, and the same sequence on every platform.
struct TickRandom: RandomNumberGenerator {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

    mutating func chance(_ probability: Double) -> Bool { probability > 0 && unit() < probability }

    /// Uniform between the bounds, to the millisecond.
    mutating func duration(_ range: ClosedRange<Duration>) -> Duration {
        let low = range.lowerBound.tickMilliseconds, high = range.upperBound.tickMilliseconds
        return .milliseconds(low + Int64(unit() * Double(high - low)))
    }

    /// Log-uniform between the bounds: as many 100 ms blips as 8 h outages
    /// per decade, so one run covers every scale.
    mutating func logDuration(_ range: ClosedRange<Duration>) -> Duration {
        let low = log(Double(max(range.lowerBound.tickMilliseconds, 1)))
        let high = log(Double(max(range.upperBound.tickMilliseconds, 1)))
        return .milliseconds(Int64(exp(low + unit() * (high - low))))
    }

    /// The seed for a cell: `TICK_SEED` when set, else the cell's fixed one.
    static func seed(default fixed: UInt64) -> UInt64 {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["TICK_SEED"] ?? environment["TEST_RUNNER_TICK_SEED"],
              let seed = UInt64(text) else { return fixed }
        return seed
    }
}

extension Duration {
    var tickMilliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
    var tickSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

