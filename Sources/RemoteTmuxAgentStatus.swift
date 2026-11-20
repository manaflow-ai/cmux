import CmuxSurfaceCatalogModel
import Foundation

/// The bounded status contract published by the pane-bound launcher's hooks.
struct RemoteTmuxAgentStatus: Decodable, Equatable, Sendable {
    enum Agent: String, Decodable, Sendable { case claude, codex }
    enum State: String, Decodable, Sendable { case working, blocked, idle }

    let agent: Agent
    let state: State

    static func parse(_ raw: String) -> Self? {
        guard raw.utf8.count <= 1024 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(raw.utf8))
    }

    var sidebarStatus: RemoteAgentSidebarStatus {
        let activity: RemoteAgentSidebarStatus.Activity
        switch state {
        case .working: activity = .running
        case .blocked: activity = .needsInput
        case .idle: activity = .idle
        }
        return RemoteAgentSidebarStatus(
            statusKey: RemoteAgentSidebarStatus.statusKeyPrefix + (agent == .claude ? "claude_code" : "codex"),
            activity: activity
        )
    }
}
