public import Foundation

/// Tab in shell mode (`shell.complete`). Not implemented yet: the red commit's API only.
public struct AgentPaneShellCompletion: Sendable {
    public nonisolated struct Word: Equatable, Sendable {
        public var start: Int
        public var text: String
        public var commandPosition: Bool
    }

    public nonisolated struct Candidate: Equatable, Sendable {
        public var value: String
        public var detail: String?
    }

    public nonisolated struct Result: Equatable, Sendable {
        public var start: Int
        public var candidates: [Candidate]
        public var truncated: Bool
    }

    public nonisolated enum Failure: Error, Equatable, Sendable {
        case folderMissing
        case spawnFailed(Int32)
        case timedOut
    }

    public init(shell: String? = ProcessInfo.processInfo.environment["SHELL"]) {}

    public func complete(_ line: String, cwd: String?) async throws(Failure) -> Result {
        Result(start: 0, candidates: [], truncated: false)
    }

    nonisolated static func word(in line: String) -> Word { Word(start: 0, text: line, commandPosition: true) }

    nonisolated static func escape(_ candidate: String, word: String) -> String { candidate }
}

extension AgentPaneModel {
    func respondToShellComplete(line: String, cwd: String?) async -> [String: Any] {
        AgentPaneReply.failure(code: "shell.failed", message: "")
    }
}
