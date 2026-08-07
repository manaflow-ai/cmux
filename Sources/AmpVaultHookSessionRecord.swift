import CMUXAgentLaunch
import Foundation

/// One Amp thread record persisted by the managed session extension.
struct AmpVaultHookSessionRecord: Decodable {
    let sessionId: String?
    let cwd: String?
    let startedAt: TimeInterval?
    let updatedAt: TimeInterval?
    let title: String?
    let launchCommand: AgentLaunchCommandSnapshot?
}
