import CmuxNextAgentPane
import CmuxNextTabs
import CmuxNextDaemon
import Foundation

/// Where an agent tab's chats run (AGENT-CWD-FOR-FOLDERLESS-WORKSPACE): the workspace's local tab
/// folders and its agent folder (the user's "Choose Folder…" pick, a cmux-tui-core workspace
/// field) are the roots; a workspace with none starts its new chats in its own agent-home folder.
extension AgentTabStore {
    /// Tab `key`'s roots, agent-home and Choose Folder… on its page's model. Each resolves the
    /// tab's current id when it runs.
    func wireAgentFolder(_ model: AgentPaneModel, key provisional: String, machine: String? = nil) {
        model.workspaceRoots = { [weak self] in self.map { $0.workspaceRoots(of: provisional, machine: machine) } ?? [] }
        model.workspaceAgentHome = { [weak self] in self.flatMap { $0.agentHome(of: provisional, machine: machine) } }
        model.transport.workspaceID = { [weak self] in self.flatMap { $0.localWorkspaceKey(of: provisional, machine: machine) } }
        // Stage and Commit (cx-tcwj) run git on this Mac, never in a Cloud or SSH chat's same-named folder here; that chat's New Worktree runs on its machine's link.
        let link: @MainActor () -> AgentPaneGitLink? = { [weak self] in self.flatMap { $0.gitLinkScoped?($0.resolvedKey(AgentTabKey(machine: machine ?? "", key: provisional))) } }
        (model.gitWritesHere, model.gitWritesOnChatMachine) = ({ link()?.isLocal == true }, { link()?.isLocal == false })
        model.startFolders.resolve = { [weak self] proposed in
            guard let self, let workspace = workspace(holding: provisional, machine: machine), let resource = workspace.resourceID else { return nil }
            guard var answer = await daemonForTabScoped(resolvedKey(AgentTabKey(machine: machine ?? "", key: provisional)))?.agentStart(proposed, workspace: resource) else { return nil }
            // The relay roots and makes agent-home: only this app's own agent-home folders, the
            // workspace's, or the one a chat opened here already ran in (cx-djoj7: the store names
            // it, so the adopt resumes there). Never a folder outside the base or deeper in it.
            if let named = answer.agentHome, named != Self.agentHomes?.path(for: workspace.id),
               Self.agentHomes?.path(for: (named as NSString).lastPathComponent) != named {
                answer.agentHome = nil
            }
            return answer
        }
        model.onChooseFolder = { [weak self] in
            guard let self else { return .cancelled }
            return await chooseAgentFolder(for: provisional, machine: machine)
        }
    }

    /// Agent chat tab `key`'s exact folder for a terminal opened from it
    /// (``AgentPaneModel/terminalFolder``). Only a chat this Mac's acpmux runs, on this Mac's
    /// daemon, in a folder that exists here: a Cloud, SSH or peer chat's folder is another
    /// machine's path, even where the same path exists here: only a shell on that machine's `daemon` gets it (Lawrence, 2026-11-08).
    func terminalFolder(of key: String, machine: String? = nil, on daemon: DaemonService? = nil) -> String? {
        let scoped = resolvedKey(tabKey(key, machine: machine ?? daemon?.machineID))
        if let daemon, !daemon.isLocal { return daemonForTabScoped(scoped) === daemon && remoteMachineID(of: scoped.key, machine: scoped.machine) == daemon.machineID ? views[scoped]?.model.terminalFolder : nil }
        guard let folder = views[scoped]?.model.terminalFolder, daemonForTabScoped(scoped)?.isLocal == true, let host = record(for: scoped)?.record.host, host == localHost, WorkingURL.isDirectory(folder) else { return nil }
        return folder
    }

    /// The workspace that holds agent tab `key`, on its local store.
    func workspace(holding key: String, machine: String? = nil) -> WorkspaceModel? {
        let scoped = tabKey(key, machine: machine)
        guard let store = tabStores[scoped] else { return nil }
        return store.workspaces.first { workspace in
            workspace.screens.contains { $0.panes.contains { $0.tabs.contains { $0.id == scoped.key } } }
        }
    }

    /// The local folders of the workspace that holds agent tab `key`: its agent folder first, then
    /// every local tab's cwd. The pane's relay limits each `cwd` and `path` the page sends to these
    /// (AcpmuxPathPolicy).
    func workspaceRoots(of key: String, machine: String? = nil) -> [String] {
        guard let workspace = workspace(holding: key, machine: machine) else { return [] }
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
    func agentHome(of key: String, machine: String? = nil) -> AgentHomeFill? {
        guard let workspace = workspace(holding: key, machine: machine), let home = Self.agentHomes, AgentHome.isSafeID(workspace.id) else { return nil }
        return AgentHomeFill(home: home, workspace: workspace.id)
    }

    /// The durable key of the workspace that holds agent tab `key`, when that workspace is this
    /// Mac's own (its daemon is local): the relay stamps it on the tab's new local chats, so this
    /// Mac's acpmux applies the workspace's sub-session limit to them. Nil for a workspace on
    /// another machine, whose key this Mac's acpmux does not know.
    func localWorkspaceKey(of key: String, machine: String? = nil) -> String? {
        let scoped = tabKey(key, machine: machine)
        guard daemonForTabScoped(resolvedKey(scoped))?.isLocal == true else { return nil }
        return workspace(holding: scoped.key, machine: scoped.machine)?.key?.rawValue
    }

    /// `~/Library/Application Support/cmux/agent-home`, read once.
    static let agentHomes = AgentHome.standard

    /// "Choose Folder…": the native folder sheet on the tab's pane, then the pick saved as the
    /// workspace's agent folder (`workspace.agent_folder.set`, which only this verified app may
    /// send). An older background service is told before the sheet opens.
    func chooseAgentFolder(for key: String, machine: String? = nil) async -> AgentPaneFolderChoice {
        let scoped = tabKey(key, machine: machine)
        guard let daemon = daemonForTabScoped(resolvedKey(scoped)), daemon.supports(DaemonCapability.workspaceAgentFolder.rawValue) else {
            return .unavailable(AgentPaneFolderChoice.restartServiceMessage)
        }
        guard let view = views[scoped], let url = await view.pickFolder() else { return .cancelled }
        let picked = url.path
        let folder = await Task.detached { AgentHome.canonicalFolder(picked) }.value
        // The home folder (or above it) would open the whole home folder to the page: refused.
        guard let folder, !AgentHome.isHomeOrAbove(folder), let workspace = workspace(holding: scoped.key, machine: scoped.machine),
              let resource = workspace.resourceID else { return .unavailable(AgentPaneFolderChoice.notSavedMessage) }
        return await Self.saveAgentFolder(folder, workspace: resource, on: daemon)
    }

    /// Saves `path` as `workspace`'s agent folder on `daemon`. A daemon without
    /// `workspace-agent-folder-v1`, or one that answers that it has no such operation (an older
    /// cmux-tui kept running across an app update), gets no retry: the user restarts it.
    static func saveAgentFolder(_ path: String, workspace: ResourceID, on daemon: DaemonService) async -> AgentPaneFolderChoice {
        guard daemon.supports(DaemonCapability.workspaceAgentFolder.rawValue) else {
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
