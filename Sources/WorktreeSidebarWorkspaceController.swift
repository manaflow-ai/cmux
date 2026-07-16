import AppKit
import Foundation

/// Bridges worktree actions to focus-preserving cmux workspace mutations.
@MainActor
struct WorktreeSidebarWorkspaceController {
    private let tabManager: TabManager

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    /// Runs a project-scoped replacement for the built-in create flow when configured.
    /// `nil` means no override was configured; `false` means the configured action
    /// could not be resolved or started and must not fall through to built-in creation.
    func executeConfiguredCreateActionIfAvailable(projectRootPath: String) -> Bool? {
        guard let store = scopedConfigStore(projectRootPath: projectRootPath),
              store.projectWorktreesCreateActionID != nil else {
            return nil
        }
        guard let action = store.resolvedProjectWorktreesCreateAction() else {
            NSSound.beep()
            return false
        }
        return executeConfiguredAction(action, store: store, baseCwd: projectRootPath)
    }

    /// Runs a project-scoped replacement for opening a worktree when configured.
    /// Workspace actions resolve relative paths against the selected worktree.
    func executeConfiguredOpenActionIfAvailable(
        projectRootPath: String,
        worktreePath: String
    ) -> Bool? {
        guard let store = scopedConfigStore(projectRootPath: projectRootPath),
              store.projectWorktreesOpenActionID != nil else {
            return nil
        }
        guard let action = store.resolvedProjectWorktreesOpenAction() else {
            NSSound.beep()
            return false
        }
        return executeConfiguredAction(action, store: store, baseCwd: worktreePath)
    }

    func openTerminal(_ request: WorktreeSidebarWorkspaceRequest) {
        tabManager.addWorkspace(
            title: request.title,
            workingDirectory: request.workingDirectory,
            inheritWorkingDirectory: request.inheritWorkingDirectory,
            select: request.select,
            eagerLoadTerminal: request.eagerLoadTerminal,
            autoWelcomeIfNeeded: false
        )
    }

    func closePlan(
        worktreePath: String,
        fallbackDirectory: String
    ) async -> WorktreeSidebarWorkspaceClosePlan {
        let managers = allTabManagers()
        let snapshotsByManager = managers.map { manager in
            manager.tabs.map { workspace in
                (
                    id: workspace.id,
                    directories: workspace.worktreeSidebarCandidateDirectories()
                )
            }
        }
        let workspaceIDsByManager = await Task.detached(priority: .utility) {
            snapshotsByManager.map { snapshots in
                Self.workspaceIDsRooted(in: worktreePath, snapshots: snapshots)
            }
        }.value
        let entries = zip(managers, workspaceIDsByManager).compactMap { pair
            -> WorktreeSidebarWorkspaceClosePlan.Entry? in
            let (manager, workspaceIDs) = pair
            guard !workspaceIDs.isEmpty else { return nil }
            return WorktreeSidebarWorkspaceClosePlan.Entry(
                manager: manager,
                workspaceIDs: workspaceIDs
            )
        }
        return WorktreeSidebarWorkspaceClosePlan(
            entries: entries,
            fallbackDirectory: fallbackDirectory
        )
    }

    func apply(_ plan: WorktreeSidebarWorkspaceClosePlan) {
        for entry in plan.entries {
            let ids = Set(entry.workspaceIDs)
            let workspaces = entry.manager.tabs.filter { ids.contains($0.id) }
            guard !workspaces.isEmpty else { continue }
            if workspaces.count >= entry.manager.tabs.count {
                entry.manager.addWorkspace(
                    workingDirectory: plan.fallbackDirectory,
                    inheritWorkingDirectory: false,
                    select: false,
                    eagerLoadTerminal: false,
                    autoWelcomeIfNeeded: false
                )
            }
            for workspace in workspaces {
                entry.manager.closeWorkspace(workspace, recordHistory: false)
            }
        }
    }

    nonisolated static func workspaceIDsRooted(
        in worktreePath: String,
        snapshots: [(id: UUID, directories: [String])]
    ) -> [UUID] {
        let target = normalizedPath(worktreePath)
        let prefix = target + "/"
        return snapshots.compactMap { snapshot in
            let matches = snapshot.directories.contains { directory in
                let candidate = normalizedPath(directory)
                return candidate == target || candidate.hasPrefix(prefix)
            }
            return matches ? snapshot.id : nil
        }
    }

    private func allTabManagers() -> [TabManager] {
        var managers = AppDelegate.shared?.allMainWindowTabManagers() ?? []
        if !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        var seen: Set<ObjectIdentifier> = []
        return managers.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    private func scopedConfigStore(projectRootPath: String) -> CmuxConfigStore? {
        guard let primaryStore = AppDelegate.shared?
            .mainWindowContext(for: tabManager)?
            .cmuxConfigStore else {
            return nil
        }
        let store = CmuxConfigStore(
            globalConfigPath: primaryStore.globalConfigPath,
            localConfigPath: primaryStore.resolvedLocalConfigPath(startingFrom: projectRootPath),
            startFileWatchers: false
        )
        store.loadAll()
        return store
    }

    private func executeConfiguredAction(
        _ action: CmuxResolvedConfigAction,
        store: CmuxConfigStore,
        baseCwd: String
    ) -> Bool {
        if case .builtIn = action.action,
           let appDelegate = AppDelegate.shared,
           let context = appDelegate.mainWindowContext(for: tabManager) {
            return appDelegate.executeConfiguredCmuxAction(action, context: context)
        }
        return CmuxConfigExecutor.execute(
            action: action,
            commands: store.loadedCommands,
            commandSourcePaths: store.commandSourcePaths,
            tabManager: tabManager,
            baseCwd: baseCwd,
            globalConfigPath: store.globalConfigPath
        )
    }

    nonisolated private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
