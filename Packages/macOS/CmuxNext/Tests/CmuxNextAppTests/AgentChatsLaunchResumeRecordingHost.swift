import CmuxNextAgentPane
import Foundation

/// Records launch warm requests for the chat-resume suite.
actor AgentChatsLaunchResumeRecordingHost: AgentPaneHostProviding {
    nonisolated let resumed: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    var warmed: [[String]] = []

    init() {
        (resumed, continuation) = AsyncStream.makeStream()
    }

    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
    func warm(sessionIds: [String]) async throws {
        warmed.append(sessionIds)
        for session in sessionIds { continuation.yield(session) }
    }
}
