import CmuxNextAgentPane
import CmuxNextOnboarding
import Foundation
import Observation

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
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let spawn = folderSpawn(folder)
            Task {
                do {
                    _ = try await windows.createWorkspace(spawn, into: target)
                } catch {
                    folderFailed(folder, error)
                }
            }
        }
    }

    /// A folder's workspace could not be made: it is no longer opening, and
    /// its waiting chats are dropped, so a later resume asks again.
    func folderFailed(_ folder: URL, _ error: any Error) {
        let path = folder.standardizedFileURL.path
        openingFolders.remove(path)
        let dropped = waitingChats.removeValue(forKey: path)?.count ?? 0
        services.daemon.logger.error(
            "onboarding workspace for a folder failed (\(dropped) chats dropped): \(String(describing: error), privacy: .public)")
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
    /// is selected when that pane is on screen. A workspace is listed before
    /// its first terminal lands, so a missing pane is waited for, a bounded
    /// number of store changes.
    private func resume(_ chats: [AgentChat], in workspace: String, changes: Int = 40) {
        guard let daemon = services.machines.daemon(forWorkspace: workspace) else {
            services.daemon.logger.error("onboarding chats: workspace \(workspace, privacy: .public) has no daemon")
            return
        }
        let store = daemon.store
        guard let pane = store.workspaces.first(where: { $0.id == workspace })?.screens.first?.panes.first else {
            guard changes > 0 else {
                services.daemon.logger.error("onboarding chats: workspace \(workspace, privacy: .public) never got a pane")
                return
            }
            withObservationTracking {
                _ = store.workspaces.first(where: { $0.id == workspace })?.screens.first?.panes.first
            } onChange: { [weak self] in
                // task-owner: one hop per store change until the first pane lands
                Task { @MainActor [weak self] in self?.resume(chats, in: workspace, changes: changes - 1) }
            }
            return
        }
        // One store tab per chat, in order; the last one is selected. A chat a tab already
        // resumes gets no second tab.
        let adopts = chats.compactMap { chat in chat.adoptHarness.map { AgentPaneAdopt(harness: $0, agentSessionId: chat.sessionID) } }
        let tabs = services.agentTabs
        let handle = pane.handle
        let controller = services.paneController(for: pane)
        services.registry.track(Task { [daemon] in
            var last: AgentTabCreated?
            for adopt in adopts where tabs.tab(resuming: adopt) == nil {
                do {
                    last = try await tabs.open(in: handle, of: daemon, seed: AgentPaneSeedSource(AgentPaneSeed(adopt: adopt)), adopt: adopt).value()
                } catch {
                    return "onboarding chats: \(error)"
                }
            }
            if let last { controller?.selectWhenReported(surface: last.surface) }
            return nil
        })
    }
}
