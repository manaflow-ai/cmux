import CmuxNextAgentPane
import Foundation

/// Records service-wired launch warm requests for the startup suite.
actor AgentChatsStartupRecordingHost: AgentPaneHostProviding {
    nonisolated let resumed: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    var calls: [String] = []

    init() {
        (resumed, continuation) = AsyncStream.makeStream()
    }

    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { .mock }
    func warm(sessionIds: [String]) async throws {
        calls.append(contentsOf: sessionIds)
        for session in sessionIds { continuation.yield(session) }
    }
}
