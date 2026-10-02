import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// The agent pane's changes view reads git through the session host:
/// `git.diff` and `git.status` with the chat session's folder as `path`.
extension DaemonService {
    /// The operation's result as JSON for the page; throws when the daemon
    /// is away or the read fails (no repository, a timeout).
    func agentPaneGit(_ request: AgentPaneGitRequest) async throws -> Data {
        guard let connection else { throw DaemonError.notConnected }
        let result = try await GitResourceClient(connection: connection).read(request.operation, params: request.sessionHostParams)
        return try JSONEncoder().encode(result)
    }
}

extension AgentPaneGitRequest {
    /// The session host's params (cmux-tui `spec/resource-operations-v2.json`).
    var sessionHostParams: [String: JSONValue] {
        switch self {
        case .diff(let cwd, let scope, let includePatch):
            ["path": .string(cwd), "scope": .string(scope.rawValue), "include_patch": .bool(includePatch)]
        case .status(let cwd):
            ["path": .string(cwd)]
        }
    }
}
