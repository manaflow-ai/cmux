import Foundation

/// A failed input: where to find it and how to replay it.
public struct FuzzFailure: Sendable, Equatable, CustomStringConvertible {
    public var name: String
    /// The run's seed. Every iteration draws from its own stream of it
    /// (`FuzzRun.generator(for:)`), so the seed and the iteration name the failing input.
    public var seed: UInt64
    /// The failing iteration; the corpus inputs, run as they are before the iterations, are -1, -2, ...
    public var iteration: Int
    /// The input bytes, for a run over inputs (`FuzzRun.forEachInput`).
    public var input: Data?
    /// What the body threw.
    public var reason: String
    /// The kept artifact (`.txt`, and `.input` next to it), when `CMUX_FUZZ_ARTIFACTS` is set.
    public var artifact: URL?
    /// The stored corpus the run read (`CMUX_FUZZ_CORPUS`), which the replay reads again.
    public var corpus: URL?

    public init(
        name: String, seed: UInt64, iteration: Int, input: Data?, reason: String, artifact: URL?, corpus: URL? = nil
    ) {
        self.name = name
        self.seed = seed
        self.iteration = iteration
        self.input = input
        self.reason = reason
        self.artifact = artifact
        self.corpus = corpus
    }

    /// The variables that replay this failure: the seed and an iteration count that ends with the
    /// failing iteration (0 for a corpus input, which runs before the iterations).
    public var replayVariables: [String: String] {
        Self.replayVariables(seed: seed, iteration: iteration, corpus: corpus)
    }

    /// The line that replays this failure, for example
    /// `CMUX_FUZZ_SEED=0x51 CMUX_FUZZ_ITERATIONS=150001 (iteration 150000 of MobileProtocol.terminalInput)`.
    public var replay: String {
        Self.replayLine(name: name, seed: seed, iteration: iteration, corpus: corpus)
    }

    public var description: String {
        var text = "\(name) failed: \(reason). Replay: \(replay)"
        if let input { text += "; input \(input.count) bytes" }
        if let artifact { text += "; kept at \(artifact.path)" }
        return text
    }

    static let replayOrder = ["CMUX_FUZZ_SEED", "CMUX_FUZZ_ITERATIONS", "CMUX_FUZZ_CORPUS"]

    static func replayVariables(seed: UInt64, iteration: Int, corpus: URL?) -> [String: String] {
        var variables = [
            "CMUX_FUZZ_SEED": "0x\(String(seed, radix: 16))",
            "CMUX_FUZZ_ITERATIONS": String(max(iteration + 1, 0)),
        ]
        if let corpus { variables["CMUX_FUZZ_CORPUS"] = corpus.path }
        return variables
    }

    static func replayLine(name: String, seed: UInt64, iteration: Int, corpus: URL?) -> String {
        let variables = replayVariables(seed: seed, iteration: iteration, corpus: corpus)
        let assignments = replayOrder.compactMap { key in variables[key].map { "\(key)=\($0)" } }
        let which = iteration >= 0 ? "iteration \(iteration)" : "corpus input \(-1 - iteration)"
        return "\(assignments.joined(separator: " ")) (\(which) of \(name))"
    }
}

public enum FuzzError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A `CMUX_FUZZ_*` variable that does not parse.
    case badVariable(name: String, value: String)
    /// A corpus file or directory that cannot be read.
    case corpusUnreadable(path: String, reason: String)
    /// The artifacts directory or an artifact that cannot be written.
    case artifactUnwritable(path: String, reason: String)
    /// A property of one input does not hold (`FuzzRun.check`).
    case property(String, location: String)
    /// The test body threw for an input.
    case failed(FuzzFailure)

    public var description: String {
        switch self {
        case let .badVariable(name, value): "\(name)=\(value) does not parse"
        case let .corpusUnreadable(path, reason): "corpus \(path) is unreadable: \(reason)"
        case let .artifactUnwritable(path, reason): "artifact \(path) is unwritable: \(reason)"
        case let .property(message, location): "\(location): \(message)"
        case let .failed(failure): failure.description
        }
    }
}
