import Foundation

/// A failed input: where to find it and how to replay it.
public struct FuzzFailure: Sendable, Equatable, CustomStringConvertible {
    public var name: String
    /// The seed of the round that failed: `CMUX_FUZZ_SEED=<seed>` replays it from its start.
    public var seed: UInt64
    public var iteration: Int
    /// The input bytes, for a run over inputs (`FuzzRun.forEachInput`).
    public var input: Data?
    /// What the body threw.
    public var reason: String
    /// The kept artifact (`.txt`, and `.input` next to it), when `CMUX_FUZZ_ARTIFACTS` is set.
    public var artifact: URL?

    public init(name: String, seed: UInt64, iteration: Int, input: Data?, reason: String, artifact: URL?) {
        self.name = name
        self.seed = seed
        self.iteration = iteration
        self.input = input
        self.reason = reason
        self.artifact = artifact
    }

    /// The line that replays this failure.
    public var replay: String {
        "CMUX_FUZZ_SEED=0x\(String(seed, radix: 16)) (iteration \(iteration) of \(name))"
    }

    public var description: String {
        var text = "\(name) failed: \(reason). Replay: \(replay)"
        if let input { text += "; input \(input.count) bytes" }
        if let artifact { text += "; kept at \(artifact.path)" }
        return text
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
