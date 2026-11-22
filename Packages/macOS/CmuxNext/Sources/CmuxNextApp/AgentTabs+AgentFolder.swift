import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

/// Where an agent tab's chats run (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE): the workspace's local tab
/// folders and its agent folder (the user's "Choose Folder…" pick, a cmux-tui-core workspace
/// field) are the roots; a workspace with none starts its new chats in its own agent-home folder.
extension AgentTabStore {
    /// Tab `key`'s roots, agent-home and Choose Folder… on its page's model. Each resolves the
    /// tab's current id when it runs.
    func wireAgentFolder(_ model: AgentPaneModel, key provisional: String) {
        model.workspaceRoots = { [weak self] in
            guard let self else { return [] }
            return workspaceRoots(of: resolve(provisional))
        }
        model.workspaceAgentHome = { [weak self] in
            guard let self else { return nil }
            return agentHome(of: resolve(provisional))
        }
        model.onChooseFolder = { [weak self] in
            guard let self else { return .cancelled }
            return await chooseAgentFolder(for: resolve(provisional))
        }
    }

    /// The workspace that holds agent tab `key`, on its local store.
    func workspace(holding key: String) -> WorkspaceModel? {
        guard let store = tabStores[key] else { return nil }
        return store.workspaces.first { workspace in
            workspace.screens.contains { $0.panes.contains { $0.tabs.contains { $0.id == key } } }
        }
    }

    /// The local folders of the workspace that holds agent tab `key`: its agent folder first, then
    /// every local tab's cwd. The pane's relay limits each `cwd` and `path` the page sends to these
    /// (AcpmuxPathPolicy).
    func workspaceRoots(of key: String) -> [String] {
        guard let workspace = workspace(holding: key) else { return [] }
        var roots: [String] = workspace.agentFolder.map { [$0] } ?? []
        for tab in workspace.screens.flatMap({ $0.panes }).flatMap({ $0.tabs }) where tab.kind != .remoteTerminal {
            if let cwd = tab.cwd, !roots.contains(cwd) { roots.append(cwd) }
        }
        return roots
    }

    /// The agent-home folder of the workspace that holds agent tab `key`, named by its durable
    /// workspace id. A root once it exists; new chats start there while the workspace has no
    /// other folder. Nil for an id that names no safe folder (the chat is then refused, never
    /// sent to the home folder).
    func agentHome(of key: String) -> AgentHomeFill? {
        guard let workspace = workspace(holding: key), let home = Self.agentHomes, AgentHome.isSafeID(workspace.id) else { return nil }
        return AgentHomeFill(home: home, workspace: workspace.id)
    }

    /// `~/Library/Application Support/cmux/agent-home`, read once.
    static let agentHomes = AgentHome.standard

    /// "Choose Folder…": the native folder sheet on the tab's pane, then the pick saved as the
    /// workspace's agent folder (`workspace.agent_folder.set`, which only this verified app may
    /// send). An older background service is told before the sheet opens.
    func chooseAgentFolder(for key: String) async -> AgentPaneFolderChoice {
        guard servesAgentFolder(key) else { return .unavailable(AgentPaneFolderChoice.restartServiceMessage) }
        guard let view = views[key], let url = await view.pickFolder() else { return .cancelled }
        let picked = url.path
        let folder = await Task.detached { AgentHome.canonicalFolder(picked) }.value
        // The home folder (or above it) would open the whole home folder to the page: refused.
        guard let folder, !AgentHome.isHomeOrAbove(folder), let workspace = workspace(holding: key),
              let resource = workspace.resourceID else { return .unavailable(AgentPaneFolderChoice.notSavedMessage) }
        return await persistAgentFolder(key, resource, folder)
    }

    /// Saves `path` as `workspace`'s agent folder on `daemon`. A daemon without
    /// `workspace-agent-folder-v1`, or one that answers that it has no such operation (an older
    /// cmux-tui kept running across an app update), gets no retry: the user restarts it.
    static func saveAgentFolder(_ path: String, workspace: ResourceID, on daemon: DaemonService) async -> AgentPaneFolderChoice {
        guard daemon.supports(DaemonCapabilities.shared.workspaceAgentFolder) else {
            return .unavailable(AgentPaneFolderChoice.restartServiceMessage)
        }
        guard let connection = daemon.connection else { return .unavailable(AgentPaneFolderChoice.notSavedMessage) }
        do {
            try await connection.state.setAgentFolder(workspace, path: path)
            return .chosen(path)
        } catch {
            daemon.logger.error("workspace.agent_folder.set: \(String(describing: error), privacy: .public)")
            if (error as? DaemonError)?.isUnknownOperation == true { return .unavailable(AgentPaneFolderChoice.restartServiceMessage) }
            return .unavailable(AgentPaneFolderChoice.notSavedMessage)
        }
    }
}
