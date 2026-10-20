import Foundation

/// One external command an agent move runs (`sh`, `ssh`, `git`, `rsync`).
public struct AgentMoveInvocation: Sendable, Equatable {
    /// The argv, program first. The program is resolved on `PATH` unless absolute.
    public var arguments: [String]
    /// Variables added to the inherited environment.
    public var environment: [String: String]
    /// Text written to standard input, or `nil` for an empty standard input.
    public var standardInput: String?

    /// Creates an invocation.
    public init(arguments: [String], environment: [String: String] = [:], standardInput: String? = nil) {
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
    }
}

/// The outcome of one ``AgentMoveInvocation``.
public struct AgentMoveCommandResult: Sendable, Equatable {
    /// Exit status.
    public var status: Int32
    /// Captured standard output.
    public var standardOutput: String
    /// Captured standard error.
    public var standardError: String

    /// Creates a result.
    public init(status: Int32, standardOutput: String = "", standardError: String = "") {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// Whether the command exited 0.
    public var succeeded: Bool { status == 0 }

    /// Standard output without surrounding whitespace.
    public var trimmedOutput: String {
        standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The most useful failure text: standard error, else standard output.
    public var failureDetail: String {
        let error = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return error.isEmpty ? trimmedOutput : error
    }
}

/// Runs external commands for an agent move. The CLI supplies a `Process`
/// runner; tests supply one that maps SSH endpoints onto local directories.
public protocol AgentMoveCommandRunning {
    /// Runs `invocation` to completion.
    func run(_ invocation: AgentMoveInvocation) throws -> AgentMoveCommandResult
}
