import CmuxNextAgentPane
import Foundation

/// A pane host that records its name by throwing on handshake.
struct ChiefSubagentNamedHost: AgentPaneHostProviding {
    let name: String
    func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw ChiefSubagentReached(host: name) }
    func sessionFolder(sessionId: String) async throws -> AgentPaneSessionFolder? { nil }
    func putFile(sessionId: String, name: String, data: Data) async throws -> String { "" }
}
