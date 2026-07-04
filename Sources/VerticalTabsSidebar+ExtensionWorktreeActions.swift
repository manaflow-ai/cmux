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
            let targetTabManagers = extensionWorktreeRemovalTabManagers()
            let windowWorkspaces = Self.extensionWorktreeRemovalWindowWorkspaces(in: targetTabManagers)
            let closePlans = Self.extensionWorktreeRemovalClosePlans(
                inWorktreePath: worktreePath,
                windowWorkspaces: windowWorkspaces
            )
            let removalPreview: (paths: [String], truncated: Bool, scanFailed: Bool)
            if safety.requiresForce {
                removalPreview = ([], false, false)
            } else {
                // A non-force git worktree removal can still delete ignored files.
                removalPreview = await CmuxExtensionWorktreePrototype.forceRemovalPreview(worktreePath: worktreePath)
            }

            guard confirmRemoveExtensionWorktree(
                worktreeName: worktreeName,
                worktreePath: worktreePath,
                closePlans: closePlans,
                safety: safety,
                removalPreview: removalPreview
            ) else { return }

            await performRemoveExtensionWorktree(
                worktreePath: worktreePath,
                worktreeName: worktreeName,
                targetTabManagers: targetTabManagers,
                closePlans: closePlans
            )
        }
    }

    func performRemoveExtensionWorktree(
        worktreePath: String,
        worktreeName: String,
        targetTabManagers: [TabManager],
        closePlans: [ExtensionWorktreeRemovalClosePlan]
    ) async {
        do {
            try await CmuxExtensionWorktreePrototype.removeWorktree(worktreePath: worktreePath, force: false)
        } catch {
            let details = (error as NSError).userInfo["CmuxExtensionWorktreePrototypeDetails"] as? String
            let message = details?.nilIfEmpty ?? error.localizedDescription
#if DEBUG
            cmuxDebugLog("extensionSidebar.worktree.remove.failed path=\(worktreePath) error=\(error.localizedDescription)")
#endif
            let forcePreview = await CmuxExtensionWorktreePrototype.forceRemovalPreview(worktreePath: worktreePath)
            if confirmForceRemoveExtensionWorktreeAfterFailure(
                worktreeName: worktreeName,
                message: message,
                previewPaths: forcePreview.paths,
                previewTruncated: forcePreview.truncated,
                previewScanFailed: forcePreview.scanFailed
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

        let parentRepo = CmuxExtensionWorktreePrototype
            .managedWorktreeIdentity(gitRootPath: worktreePath)?.parentRepoPath

        for plan in closePlans where plan.needsReplacement {
            guard targetTabManagers.indices.contains(plan.windowIndex) else { continue }
            let manager = targetTabManagers[plan.windowIndex]
            manager.addWorkspace(
                workingDirectory: parentRepo,
                inheritWorkingDirectory: parentRepo == nil,
                select: true,
                eagerLoadTerminal: false
            )
        }

        for plan in closePlans {
            guard targetTabManagers.indices.contains(plan.windowIndex) else { continue }
            let manager = targetTabManagers[plan.windowIndex]
            let idsToClose = Set(plan.workspaceIds)
            let workspacesToClose = manager.tabs.filter { idsToClose.contains($0.id) }
            for workspace in workspacesToClose {
                manager.closeWorkspace(workspace, recordHistory: false)
            }
        }
        refreshExtensionSidebarSnapshot()
    }

    typealias ExtensionWorktreeRemovalWorkspaceSnapshot = (
        id: UUID,
        title: String,
        candidateDirectories: [String?]
    )

    typealias ExtensionWorktreeRemovalClosePlan = (
        windowIndex: Int,
        workspaceIds: [UUID],
        workspaceTitles: [String],
        needsReplacement: Bool
    )

    static func extensionWorktreeRemovalClosePlans(
        inWorktreePath worktreePath: String,
        windowWorkspaces: [[ExtensionWorktreeRemovalWorkspaceSnapshot]]
    ) -> [ExtensionWorktreeRemovalClosePlan] {
        windowWorkspaces.enumerated().compactMap { index, workspaces in
            let workspaceIds = CmuxExtensionWorktreePrototype.workspaceIdsRooted(
                inWorktreePath: worktreePath,
                workspaces: workspaces.map {
                    (id: $0.id, candidateDirectories: $0.candidateDirectories)
                }
            )
            guard !workspaceIds.isEmpty else { return nil }
            let titleByWorkspaceId = Dictionary(
                uniqueKeysWithValues: workspaces.map { ($0.id, $0.title) }
            )
            let workspaceTitles = workspaceIds.compactMap { titleByWorkspaceId[$0] }
            return (
                windowIndex: index,
                workspaceIds: workspaceIds,
                workspaceTitles: workspaceTitles,
                needsReplacement: CmuxExtensionWorktreePrototype.replacementWorkspaceNeeded(
                    totalWorkspaceCount: workspaces.count,
                    closingCount: workspaceIds.count
                )
            )
        }
    }

    private static func extensionWorktreeRemovalWindowWorkspaces(
        in targetTabManagers: [TabManager]
    ) -> [[ExtensionWorktreeRemovalWorkspaceSnapshot]] {
        targetTabManagers.map { manager in
            manager.tabs.map { workspace in
                (
                    id: workspace.id,
                    title: manager.resolvedWorkspaceDisplayTitle(for: workspace),
                    candidateDirectories: workspace.extensionWorktreeRemovalCandidateDirectories()
                )
            }
        }
    }

    private func extensionWorktreeRemovalTabManagers() -> [TabManager] {
        var managers = AppDelegate.shared?.allMainWindowTabManagers() ?? []
        if !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        return managers
    }
}

extension Workspace {
    func extensionWorktreeRemovalCandidateDirectories() -> [String?] {
        guard !isRemoteWorkspace, !isRemoteTmuxMirror else { return [] }

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
