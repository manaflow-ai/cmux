import Foundation

/// How a property-test run behaves, read from the environment:
///
/// - `CMUX_FUZZ_SECONDS`: long mode. Each run keeps going past its default
///   iterations until this many seconds have passed. It counts per run: a suite of
///   ten runs on one thread takes ten times as long.
/// - `CMUX_FUZZ_DEADLINE`: long mode with one end for every run in the process, as
///   Unix time in seconds (`$(( $(date +%s) + 300 ))`). Runs on parallel threads
///   all end there, so `swift test --filter <Suite>` spends the budget once per
///   suite; the runs of a serialized or `@MainActor` suite go one after another,
///   and the first one takes what is left of the budget. With both variables set, a
///   run stops at the earlier end.
/// - `CMUX_FUZZ_ITERATIONS`: replay. Every run makes exactly this many iterations
///   (`0..<n`) after its corpus inputs and long mode is off, so a failure's replay
///   line (`CMUX_FUZZ_SEED=... CMUX_FUZZ_ITERATIONS=...`) runs the same iterations
///   up to the failing one on any machine.
/// - `CMUX_FUZZ_SEED`: replaces every run's seed (decimal or `0x` hex).
/// - `CMUX_FUZZ_ARTIFACTS`: a directory for failing inputs. While a run goes, its
///   current iteration and replay line sit in `<name>.inflight` (and its input in
///   `.inflight.input`), so a trap leaves them behind; a thrown failure is kept as
///   `<name>-<seed>-<iteration>`.
/// - `CMUX_FUZZ_CORPUS`: a directory of stored inputs; `<corpus>/<name>/*` run first.
public struct FuzzEnvironment: Sendable, Equatable {
    public var seconds: Double?
    public var deadline: Date?
    public var iterations: Int?
    public var seed: UInt64?
    public var artifacts: URL?
    public var corpus: URL?

    public init(
        seconds: Double? = nil, deadline: Date? = nil, iterations: Int? = nil, seed: UInt64? = nil,
        artifacts: URL? = nil, corpus: URL? = nil
    ) {
        self.seconds = seconds
        self.deadline = deadline
        self.iterations = iterations
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
        if let raw = value("CMUX_FUZZ_DEADLINE") {
            guard let unix = Double(raw), unix.isFinite, unix >= 0 else {
                throw FuzzError.badVariable(name: "CMUX_FUZZ_DEADLINE", value: raw)
            }
            deadline = Date(timeIntervalSince1970: unix)
        }
        if let raw = value("CMUX_FUZZ_ITERATIONS") {
            guard let count = Int(raw), count >= 0 else {
                throw FuzzError.badVariable(name: "CMUX_FUZZ_ITERATIONS", value: raw)
            }
            iterations = count
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

    /// Whether runs go on past their default iterations (a replay count turns it off).
    public var isLongMode: Bool {
        iterations == nil && (seconds != nil || deadline != nil)
    }

    /// How long a run that starts at `now` may go on in long mode: the earlier end of `seconds`
    /// and `deadline`, never below 0; nil when long mode is off.
    public func longModeBudget(from now: Date) -> TimeInterval? {
        guard isLongMode else { return nil }
        let ends = [seconds, deadline.map { $0.timeIntervalSince(now) }].compactMap { $0 }
        return ends.min().map { max($0, 0) }
    }
}
