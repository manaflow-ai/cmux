import CmuxNextAgentPane
import CmuxNextOnboarding
import Foundation

/// The chats step: resumed chats open as agent tabs in their project's
/// workspace, which the projects step may have opened a moment before.
extension AppOnboardingServices {
    func scanAgentChats() async -> [AgentChat] {
        await Task.detached { AgentChatScan(projects: .live()).run() }.value
    }

    func resumeChats(_ chats: [AgentChat]) {
        let byFolder = Dictionary(grouping: chats.filter { $0.adoptHarness != nil }) { $0.folder.standardizedFileURL.path }
        for (path, chats) in byFolder {
            if let workspace = folderWorkspaces[path] {
                resume(chats, in: workspace)
                continue
            }
            waitingChats[path, default: []] += chats
            guard !openingFolders.contains(path), let windows = services.windows else { continue }
            let target = windows.targetWindow(preferring: windows.active?.state.id)
            let logger = services.daemon.logger
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            Task {
                do {
                    _ = try await windows.createWorkspace(folderSpawn(folder), into: target)
                } catch {
                    logger.error("onboarding chat workspace failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// A workspace for `folder`, named after it, that records itself once
    /// listed and takes the chats waiting for it.
    func folderSpawn(_ folder: URL) -> WorkspaceSpawn {
        let path = folder.standardizedFileURL.path
        openingFolders.insert(path)
        var spawn = WorkspaceSpawn(cwd: folder.path, name: folder.lastPathComponent)
        spawn.onListed = { [weak self] workspace, _ in
            guard let self else { return }
            openingFolders.remove(path)
            folderWorkspaces[path] = workspace
            if let chats = waitingChats.removeValue(forKey: path) { resume(chats, in: workspace) }
        }
        return spawn
    }

    /// Each chat as an agent tab in the workspace's first pane; the last one
    /// is selected when that pane is on screen.
    private func resume(_ chats: [AgentChat], in workspace: String) {
        guard let daemon = services.machines.daemon(forWorkspace: workspace),
              let pane = daemon.store.workspaces.first(where: { $0.id == workspace })?.screens.first?.panes.first else {
            services.daemon.logger.error("onboarding chats: workspace \(workspace, privacy: .public) has no pane")
            return
        }
        var last: String?
        for chat in chats {
            guard let harness = chat.adoptHarness else { continue }
            last = services.agentTabs.resume(AgentPaneAdopt(harness: harness, agentSessionId: chat.sessionID), in: pane.id, of: daemon.store)
        }
        if let last { services.paneController(for: pane)?.showAgentTab(last) }
    }
}
