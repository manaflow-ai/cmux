import CmuxNextAgentPane
import Foundation

/// Records launch warm requests for the chat-resume suite.
actor AgentChatsLaunchResumeRecordingHost: AgentPaneHostProviding {
    nonisolated let resumed: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    var warmed: [[String]] = []

    private var failures: Int
    private let blocked: Bool

    init(failures: Int = 0, blocked: Bool = false) {
        self.failures = failures
        self.blocked = blocked
        (resumed, continuation) = AsyncStream.makeStream()
    }

    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
    func warm(sessionIds: [String]) async throws {
        warmed.append(sessionIds)
        for session in sessionIds { continuation.yield(session) }
        if failures > 0 {
            failures -= 1
            throw AgentPaneHostError.daemonRestarting
        }
        if blocked {
            let (stream, hold) = AsyncStream<Void>.makeStream()
            defer { hold.finish() }
            for await _ in stream {}
            try Task.checkCancellation()
        }
    }
}
