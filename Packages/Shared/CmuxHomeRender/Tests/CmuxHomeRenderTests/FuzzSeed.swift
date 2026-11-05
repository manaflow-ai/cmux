import Foundation
import Testing

/// The seed and iteration scale of one seeded fuzz test, read once from the
/// environment when the test starts; the test passes ``seed`` to its generator.
///
/// - No `CMUX_FUZZ_SEED`: the test's own fixed seed, so CI replays the same inputs.
/// - `CMUX_FUZZ_SEED=<u64>` (decimal or `0x` hex, not 0): that seed.
/// - `CMUX_FUZZ_SEED=random`: a new seed from the system generator, so a
///   repeated run explores new inputs.
/// - `CMUX_FUZZ_ITERATIONS=<n>`: each fuzz loop runs n times its count (default 1).
///
/// ``description`` is the environment that repeats the run. It is printed when
/// the test starts (to standard error), so a trap's log names it, and the test puts it in the
/// message of every expectation and caught error of its fuzz loop.
///
/// Each package with fuzz suites keeps one identical copy of this file (the
/// packages share no test support module).
struct FuzzSeed: CustomStringConvertible, Sendable {
    let seed: UInt64
    let scale: Int

    init(
        default fixed: UInt64,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileID: String = #fileID,
        function: String = #function
    ) {
        seed = Self.seed(environment["CMUX_FUZZ_SEED"], default: fixed)
        scale = Self.scale(environment["CMUX_FUZZ_ITERATIONS"])
        // Unbuffered standard error, so the line is in the log even when the test traps.
        FileHandle.standardError.write(Data("\(fileID) \(function): \(self)\n".utf8))
    }

    /// `base` times the scale, saturating at `Int.max`.
    func iterations(_ base: Int) -> Int {
        let (product, overflow) = base.multipliedReportingOverflow(by: scale)
        return overflow ? Int.max : product
    }

    var description: String { "CMUX_FUZZ_SEED=\(seed) CMUX_FUZZ_ITERATIONS=\(scale)" }

    /// Runs `body`; an error it throws fails the test with an issue that names the seed.
    func run(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            Issue.record(error, "\(self)")
        }
    }

    private static func seed(_ value: String?, default fixed: UInt64) -> UInt64 {
        guard let value else { return fixed }
        if value == "random" { return UInt64.random(in: 1 ... UInt64.max) }
        let parsed = value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
        // The xorshift generators never leave state 0, so 0 is refused like any other bad value.
        guard let parsed, parsed != 0 else {
            Issue.record("CMUX_FUZZ_SEED must be a nonzero u64 or random, got '\(value)'")
            return fixed
        }
        return parsed
    }

    private static func scale(_ value: String?) -> Int {
        guard let value else { return 1 }
        guard let parsed = Int(value), parsed > 0 else {
            Issue.record("CMUX_FUZZ_ITERATIONS must be a positive whole number, got '\(value)'")
            return 1
        }
        return parsed
    }
}
