import Foundation

/// How a property-test run behaves, read from the environment:
///
/// - `CMUX_FUZZ_SECONDS`: long mode. A run keeps going past its default
///   iterations, round after round with new seeds, until this many seconds pass
///   (per run, so per test). Unset or 0: the default iterations only.
/// - `CMUX_FUZZ_SEED`: replaces every run's seed (decimal or `0x` hex); a failure
///   names the seed to set.
/// - `CMUX_FUZZ_ARTIFACTS`: a directory for failing inputs. While a run goes, its
///   current input sits in `<name>.inflight` (and `.inflight.input`), so a trap
///   leaves it behind; a thrown failure is kept as `<name>-<seed>-<iteration>`.
/// - `CMUX_FUZZ_CORPUS`: a directory of stored inputs; `<corpus>/<name>/*` run first.
public struct FuzzEnvironment: Sendable, Equatable {
    public var seconds: Double?
    public var seed: UInt64?
    public var artifacts: URL?
    public var corpus: URL?

    public init(seconds: Double? = nil, seed: UInt64? = nil, artifacts: URL? = nil, corpus: URL? = nil) {
        self.seconds = seconds
        self.seed = seed
        self.artifacts = artifacts
        self.corpus = corpus
    }

    /// Reads the `CMUX_FUZZ_*` variables; a value that does not parse is an error, never ignored.
    public init(variables: [String: String]) throws(FuzzError) {
        func value(_ name: String) -> String? {
            guard let raw = variables[name]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return raw
        }
        if let raw = value("CMUX_FUZZ_SECONDS") {
            guard let seconds = Double(raw), seconds.isFinite, seconds >= 0 else {
                throw FuzzError.badVariable(name: "CMUX_FUZZ_SECONDS", value: raw)
            }
            self.seconds = seconds > 0 ? seconds : nil
        }
        if let raw = value("CMUX_FUZZ_SEED") {
            let lower = raw.lowercased()
            let parsed = lower.hasPrefix("0x") ? UInt64(lower.dropFirst(2), radix: 16) : UInt64(lower)
            guard let parsed else { throw FuzzError.badVariable(name: "CMUX_FUZZ_SEED", value: raw) }
            seed = parsed
        }
        artifacts = value("CMUX_FUZZ_ARTIFACTS").map { URL(fileURLWithPath: $0, isDirectory: true) }
        corpus = value("CMUX_FUZZ_CORPUS").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The test process's environment.
    public static func current() throws(FuzzError) -> FuzzEnvironment {
        try FuzzEnvironment(variables: ProcessInfo.processInfo.environment)
    }

    /// Whether runs go on past their default iterations.
    public var isLongMode: Bool { (seconds ?? 0) > 0 }
}
