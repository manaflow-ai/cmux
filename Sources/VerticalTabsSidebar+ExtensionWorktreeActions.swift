import AppKit
import CmuxFoundation
import CmuxSidebarProviderKit
import Foundation

extension VerticalTabsSidebar {
    func createExtensionWorktreeWorkspace(for section: CmuxSidebarProviderTreeSection) {
        guard let projectRootPath = section.projectRootPath,
              !extensionSidebarWorktreeCreationInFlightSectionIds.contains(section.id) else {
            return
        }

        extensionSidebarWorktreeCreationInFlightSectionIds.insert(section.id)
        Task {
            do {
                let result = try await CmuxExtensionWorktreePrototype.createWorktree(projectRootPath: projectRootPath)
                let spawnArgs = result.workspaceSpawnArgs()
                tabManager.addWorkspace(
                    title: spawnArgs.title,
                    workingDirectory: spawnArgs.workingDirectory,
                    initialTerminalInput: spawnArgs.initialTerminalInput,
                    inheritWorkingDirectory: spawnArgs.inheritWorkingDirectory,
                    select: true,
                    eagerLoadTerminal: false,
                    autoWelcomeIfNeeded: spawnArgs.initialTerminalInput == nil
                )
            } catch {
                NSSound.beep()
#if DEBUG
                cmuxDebugLog("extensionSidebar.worktree.failed project=\(projectRootPath) error=\(error.localizedDescription)")
#endif
            }
            extensionSidebarWorktreeCreationInFlightSectionIds.remove(section.id)
        }
    }

    /// Opens a stable terminal workspace rooted at an existing worktree path.
    func openTerminalInExtensionWorktree(worktreePath: String) {
        let args = CmuxExtensionWorktreePrototype.openTerminalArgs(worktreePath: worktreePath)
        tabManager.addWorkspace(
            title: args.title,
            workingDirectory: args.workingDirectory,
            inheritWorkingDirectory: args.inheritWorkingDirectory,
            select: true,
            eagerLoadTerminal: false
        )
    }

    /// Inspects safety state, confirms removal, removes the worktree, and closes rooted tabs.
    func requestRemoveExtensionWorktree(worktreePath: String) {
        Task { @MainActor in
            let safety: CmuxExtensionWorktreeRemovalSafety
            do {
                safety = try await CmuxExtensionWorktreePrototype.inspectRemovalSafety(worktreePath: worktreePath)
            } catch {
                // Unknown safety state always confirms and lets git refuse dirty removal.
                safety = CmuxExtensionWorktreeRemovalSafety(
                    hasUncommittedChanges: false,
                    unpushedCommitCount: 0,
                    inspectionFailed: true
                )
            }

            let worktreeName = URL(fileURLWithPath: worktreePath, isDirectory: true).lastPathComponent

            guard confirmRemoveExtensionWorktree(worktreeName: worktreeName, safety: safety) else { return }

            await performRemoveExtensionWorktree(
                worktreePath: worktreePath,
                worktreeName: worktreeName
            )
        }
    }

    func performRemoveExtensionWorktree(
        worktreePath: String,
        worktreeName: String
    ) async {
        do {
            try await CmuxExtensionWorktreePrototype.removeWorktree(worktreePath: worktreePath, force: false)
        } catch {
            let details = (error as NSError).userInfo["CmuxExtensionWorktreePrototypeDetails"] as? String
            let message = details?.nilIfEmpty ?? error.localizedDescription
#if DEBUG
            cmuxDebugLog("extensionSidebar.worktree.remove.failed path=\(worktreePath) error=\(error.localizedDescription)")
#endif
            if confirmForceRemoveExtensionWorktreeAfterFailure(
                worktreeName: worktreeName,
                message: message
            ) {
                do {
                    try await CmuxExtensionWorktreePrototype.removeWorktree(worktreePath: worktreePath, force: true)
                } catch {
                    NSSound.beep()
#if DEBUG
                    cmuxDebugLog("extensionSidebar.worktree.forceRemove.failed path=\(worktreePath) error=\(error.localizedDescription)")
#endif
                    let forceDetails = (error as NSError).userInfo["CmuxExtensionWorktreePrototypeDetails"] as? String
                    presentExtensionWorktreeRemovalFailure(
                        worktreeName: worktreeName,
                        message: forceDetails?.nilIfEmpty ?? error.localizedDescription
                    )
                    return
                }
            } else {
                return
            }
        }

        let targetTabManagers = extensionWorktreeRemovalTabManagers()
        let windowWorkspaces = targetTabManagers.map { manager in
            manager.tabs.map {
                (
                    id: $0.id,
                    candidateDirectories: $0.extensionWorktreeRemovalCandidateDirectories()
                )
            }
        }
        let closePlans = Self.extensionWorktreeRemovalClosePlans(
            inWorktreePath: worktreePath,
            windowWorkspaces: windowWorkspaces
        )
        let parentRepo = CmuxExtensionWorktreePrototype
            .managedWorktreeIdentity(gitRootPath: worktreePath)?.parentRepoPath

        for plan in closePlans where plan.needsReplacement {
            let manager = targetTabManagers[plan.windowIndex]
            manager.addWorkspace(
                workingDirectory: parentRepo,
                inheritWorkingDirectory: parentRepo == nil,
                select: true,
                eagerLoadTerminal: false
            )
        }

        for plan in closePlans {
            let manager = targetTabManagers[plan.windowIndex]
            let idsToClose = Set(plan.workspaceIds)
            let workspacesToClose = manager.tabs.filter { idsToClose.contains($0.id) }
            for workspace in workspacesToClose {
                manager.closeWorkspace(workspace, recordHistory: false)
            }
        }
        refreshExtensionSidebarSnapshot()
    }

    static func extensionWorktreeRemovalClosePlans(
        inWorktreePath worktreePath: String,
        windowWorkspaces: [[(id: UUID, candidateDirectories: [String?])]]
    ) -> [(windowIndex: Int, workspaceIds: [UUID], needsReplacement: Bool)] {
        windowWorkspaces.enumerated().compactMap { index, workspaces in
            let workspaceIds = CmuxExtensionWorktreePrototype.workspaceIdsRooted(
                inWorktreePath: worktreePath,
                workspaces: workspaces
            )
            guard !workspaceIds.isEmpty else { return nil }
            return (
                windowIndex: index,
                workspaceIds: workspaceIds,
                needsReplacement: CmuxExtensionWorktreePrototype.replacementWorkspaceNeeded(
                    totalWorkspaceCount: workspaces.count,
                    closingCount: workspaceIds.count
                )
            )
        }
    }

    private func extensionWorktreeRemovalTabManagers() -> [TabManager] {
        var managers = AppDelegate.shared?.allMainWindowTabManagersForDebug() ?? []
        if !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        return managers
    }
}

private extension Workspace {
    func extensionWorktreeRemovalCandidateDirectories() -> [String?] {
        var directories: [String?] = [currentDirectory]
        directories.append(contentsOf: panelDirectories.values.map(Optional.some))

        for panel in panels.values {
            if let terminalPanel = panel as? TerminalPanel {
                directories.append(terminalPanel.requestedWorkingDirectory)
            }
            if let agentPanel = panel as? AgentSessionPanel {
                directories.append(agentPanel.workingDirectory)
            }
        }

        return directories
    }
}
