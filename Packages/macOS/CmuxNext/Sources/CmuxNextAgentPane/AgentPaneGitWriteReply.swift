import Foundation

/// The page's git writes: `git.commit` / `git.push` from the changes view and a new chat's
/// `git.worktree.create` (cx-lyqio.2). Its own type, so the pane model only forwards to it.
@MainActor
enum AgentPaneGitWriteReply {
    /// A commit or push runs in the folder of the pane's own session (from the host), never a
    /// folder the page names, and only when the page read the repository for that same session.
    static func reply(to write: AgentPaneGitWrite, in model: AgentPaneModel) async -> [String: Any] {
        let message = AgentPaneModel.gitWriteFailedMessage
        guard let onGitWrite = model.onGitWrite else { return AgentPaneModel.gitFailure(.notConnected, message: message) }
        // Only a chat whose repository is this Mac's writes (the same rule as Stage, cx-tcwj).
        guard model.gitWritesHere?() == true else { return AgentPaneModel.gitFailure(.noSessionFolder, message: message) }
        if case .worktree(let cwd, _, _) = write { return await newWorktree(write, in: cwd, model: model) }
        guard let sessionId = model.sessionId else { return AgentPaneModel.gitFailure(.noSessionFolder, message: message) }
        guard write.sessionId == sessionId else { return AgentPaneModel.gitFailure(.sessionChanged, message: message) }
        let folder: AgentPaneSessionFolder?
        do {
            folder = try await model.host.sessionFolder(sessionId: sessionId)
        } catch {
            return AgentPaneModel.gitFailure(.notConnected, message: message)
        }
        guard let folder, folder.isLocal, folder.cwd.hasPrefix("/") else {
            return AgentPaneModel.gitFailure(.noSessionFolder, message: message)
        }
        return await AgentPaneModel.gitReply(message: message) { try await onGitWrite(write, folder.cwd) }
    }

    /// New Worktree: a new chat's own worktree of `cwd`, made on the user's click, only before
    /// the chat starts and only of a folder this pane has (a workspace root or the chat's start
    /// folder), so a page cannot branch an arbitrary repository. The page then starts the chat in
    /// the worktree through `workspace.useFolder`.
    private static func newWorktree(_ write: AgentPaneGitWrite, in cwd: String, model: AgentPaneModel) async -> [String: Any] {
        let message = AgentPaneModel.gitWriteFailedMessage
        guard let onGitWrite = model.onGitWrite else { return AgentPaneModel.gitFailure(.notConnected, message: message) }
        guard model.sessionId == nil else { return AgentPaneModel.gitFailure(.sessionChanged, message: message) }
        let folders = (model.workspaceRoots?() ?? []) + [model.startFolders.current(of: model)].compactMap { $0 }
        guard folders.contains(cwd) else { return AgentPaneModel.gitFailure(.noSessionFolder, message: message) }
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        return await AgentPaneModel.gitReply(message: message) { try await onGitWrite(write, cwd) }
    }
}
