import CMUXAgentLaunch
import Foundation

struct AmpIndexedSession {
    let sessionId: String
    let title: String
    let cwd: String?
    let launchCommand: AgentLaunchCommandSnapshot?
    let modified: Date
}
