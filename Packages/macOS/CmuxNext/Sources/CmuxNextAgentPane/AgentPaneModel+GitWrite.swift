import Foundation

extension AgentPaneModel {
    /// `git.commit` / `git.push` from the changes view: runs in the folder of
    /// the pane's own session (from the host), never a folder the page names,
    /// and only when the page read the repository for that same session.
    func respondToGitWrite(_ write: AgentPaneGitWrite) async -> [String: Any] {
        let message = Self.gitWriteFailedMessage
        guard let onGitWrite else { return Self.gitFailure(.notConnected, message: message) }
        guard let sessionId else { return Self.gitFailure(.noSessionFolder, message: message) }
        guard write.sessionId == sessionId else { return Self.gitFailure(.sessionChanged, message: message) }
        let folder: AgentPaneSessionFolder?
        do {
            folder = try await host.sessionFolder(sessionId: sessionId)
        } catch {
            return Self.gitFailure(.notConnected, message: message)
        }
        guard let folder, folder.isLocal, folder.cwd.hasPrefix("/") else {
            return Self.gitFailure(.noSessionFolder, message: message)
        }
        return await Self.gitReply(message: message) { try await onGitWrite(write, folder.cwd) }
    }
}
