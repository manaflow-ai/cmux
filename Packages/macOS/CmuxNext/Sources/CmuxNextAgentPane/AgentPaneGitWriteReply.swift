import Foundation

/// The page's git writes: `git.commit` / `git.push` from the changes view, a new chat's
/// `git.worktree.create` (cx-lyqio.2) and a worktree chat's `git.worktree.apply` (cx-lyqio.4) and
/// `git.worktree.remove` (cx-lyqio.5).
/// Its own type, so the pane model only forwards to it.
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
        // Apply changes the user's own checkout and Remove deletes a folder: only on their click.
        switch write {
        case .worktreeApply, .worktreeRemove:
            if !model.transport.gestures.consume() { return AgentPaneModel.transportFailure(.gestureRequired) }
        default:
            break
        }
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

    /// New Worktree: a new chat's own worktree of `cwd`, made on the user's click and only before
    /// the chat starts. The folder passes the same check as one the user picks for a chat
    /// (`workspace.useFolder`): a project folder, never the home folder or a folder above it, and
    /// the worktree is made of the folder as that check names it (symlinks resolved). The page then
    /// starts the chat in the worktree through `workspace.useFolder`.
    private static func newWorktree(_ write: AgentPaneGitWrite, in cwd: String, model: AgentPaneModel) async -> [String: Any] {
        let message = AgentPaneModel.gitWriteFailedMessage
        guard let onGitWrite = model.onGitWrite else { return AgentPaneModel.gitFailure(.notConnected, message: message) }
        guard model.sessionId == nil else { return AgentPaneModel.gitFailure(.sessionChanged, message: message) }
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        let answer = await model.startFolders.use(cwd, confirm: false, transport: model.transport)
        guard let value = answer["value"] as? [String: Any], value["status"] as? String == "ok",
              let folder = value["cwd"] as? String, folder.hasPrefix("/") else {
            return AgentPaneModel.gitFailure(.noSessionFolder, message: message)
        }
        guard case .worktree(_, let name, let key) = write else { return AgentPaneModel.gitFailure(.failed, message: message) }
        let named = AgentPaneGitWrite.worktree(cwd: folder, name: name, key: key)
        return await AgentPaneModel.gitReply(message: message) { try await onGitWrite(named, folder) }
    }
}
