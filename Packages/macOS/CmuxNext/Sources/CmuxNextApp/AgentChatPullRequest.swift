import CmuxNextAgentPane
import Foundation
import Observation

nonisolated struct AgentChatPullRequestReader: Sendable {
    var gh: String?

    func read(in folder: String) async -> AgentPanePullRequest? {
        nil
    }
}

@MainActor @Observable
final class AgentChatPullRequest {
    init(reader: AgentChatPullRequestReader) {}

    func badge(cwd: String?) -> AgentPanePullRequest? {
        nil
    }
}
