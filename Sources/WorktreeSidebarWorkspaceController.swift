import Foundation

/// Bridges worktree actions to focus-preserving cmux workspace mutations.
@MainActor
struct WorktreeSidebarWorkspaceController {
    private let tabManager: TabManager

    init(tabManager: TabManager) {
        self.tabManager = tabManager
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
    ) -> WorktreeSidebarWorkspaceClosePlan {
        let managers = allTabManagers()
        let entries = managers.compactMap { manager -> WorktreeSidebarWorkspaceClosePlan.Entry? in
            let snapshots = manager.tabs.map { workspace in
                (
                    id: workspace.id,
                    directories: workspace.worktreeSidebarCandidateDirectories()
                )
            }
            let workspaceIDs = Self.workspaceIDsRooted(
                in: worktreePath,
                snapshots: snapshots
            )
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

    nonisolated private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
