import CmuxSettings
import CmuxWorkspaces
import Foundation

extension DockSplitStore {
    static func normalizedBaseDirectory(_ directory: String?) -> String? {
        let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func resolvedTerminalStartupWorkingDirectory(
        kind: DockSurfaceKind,
        requestedWorkingDirectory: String?,
        sourcePanelId: UUID?,
        allowsDeclarativeDefaults: Bool = true
    ) -> String {
        let remoteOwner = terminalFontSizeOwningWorkspace.map {
            $0.isRemoteWorkspace || $0.isRemoteTmuxMirror
        } == true
        let baseDirectory = remoteOwner
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : currentBaseDirectory()
        guard kind == .terminal else { return baseDirectory }
        if !allowsDeclarativeDefaults {
            if let requestedDirectory = TerminalWorkingDirectoryResolver.normalized(requestedWorkingDirectory) {
                return requestedDirectory
            }
            if !remoteOwner, let sourcePanelId,
               let inheritedDirectory = inheritedLocalTerminalWorkingDirectory(for: sourcePanelId),
               !inheritedDirectory.isEmpty {
                return inheritedDirectory
            }
            return baseDirectory
        }

        let legacyInheritanceEnabled = settings.value(
            for: settingsCatalog.app.workspaceInheritWorkingDirectory
        )
        let declarative = declarativeTerminalConfigurationCache.snapshot(
            fileURL: declarativeTerminalConfigurationFileURL
        )
        let policy = declarative.effectiveWorkingDirectoryPolicy(
            legacyInheritanceEnabled: legacyInheritanceEnabled
        )
        let inheritedDirectory = policy == .inheritActivePane && !remoteOwner
            ? sourcePanelId.flatMap { inheritedLocalTerminalWorkingDirectory(for: $0) }
            : nil
        return WorkspaceCreationWorkingDirectoryPolicy(
            policy: policy,
            fixedPath: declarative.workingDirectoryPath
        ).resolve(
            explicitWorkingDirectory: requestedWorkingDirectory,
            inheritedWorkingDirectory: inheritedDirectory,
            defaultWorkingDirectory: baseDirectory,
            workspaceRootWorkingDirectory: remoteOwner
                ? nil
                : terminalFontSizeOwningWorkspace?.workspaceRootDirectory ?? baseDirectory
        )
    }

    /// Returns a source directory only when it is valid for a new local terminal.
    func inheritedLocalTerminalWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard detachedSurfaceTransfersByPanelId[sourcePanelId]?.isRemoteTerminal != true else { return nil }
        return terminalWorkingDirectory(for: sourcePanelId)
    }

    /// Returns the best current directory owned by a Dock terminal.
    ///
    /// Local terminals prefer the shell integration report owned by their
    /// surface, then fall back to foreground-process inspection. A restored
    /// agent that is still auto-resuming retains the pre-report candidate order
    /// so an early shell-home report cannot bypass its cwd rescue state. Remote
    /// terminals must keep their transferred remote directory because their
    /// local process is only the relay.
    func terminalWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard let terminal = panels[sourcePanelId] as? TerminalPanel else { return nil }
        let transfer = detachedSurfaceTransfersByPanelId[sourcePanelId]
        if transfer?.isRemoteTerminal == true {
            return TerminalWorkingDirectoryResolver.firstAvailable([
                transfer?.directory,
                terminal.directory,
                terminal.requestedWorkingDirectory,
            ])
        }
        let existingCandidates = [
            terminalWorkingDirectoryResolver.liveForegroundProcessWorkingDirectory(for: terminal),
            terminal.directory,
            transfer?.directory,
            terminal.requestedWorkingDirectory,
        ]
        let reportedDirectory = terminal.surface.reportedWorkingDirectory
        if restoredAgentLifecycle.resumeStatesByPanelId[sourcePanelId] == .autoResumeCommandRunning {
            return TerminalWorkingDirectoryResolver.firstAvailable(existingCandidates)
                ?? reportedDirectory.flatMap { $0.isEmpty ? nil : $0 }
        }
        return reportedDirectory.flatMap { $0.isEmpty ? nil : $0 }
            ?? TerminalWorkingDirectoryResolver.firstAvailable(existingCandidates)
    }

    /// Selects project lookup only when its directory provenance is local or
    /// trusted. A denied remote directory must not fall back to the app's PWD.
    func agentLifecycleRegistryScope(
        for sourcePanelId: UUID
    ) -> ControlSidebarAgentLifecycleRegistryScope {
        let transfer = detachedSurfaceTransfersByPanelId[sourcePanelId]
        if transfer?.isRemoteTerminal == true {
            return .globalOnly
        }
        guard let directory = TerminalWorkingDirectoryResolver.normalized(
            terminalWorkingDirectory(for: sourcePanelId)
        ) else {
            return .globalOnly
        }
        return .project(directory)
    }
}
