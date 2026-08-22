import CmuxSettings
import CmuxWorkspaces
import Foundation

extension Workspace {
    /// Resolves the working directory for an ordinary new local terminal from
    /// the declarative `cmux.json` policy. Explicit requests always win;
    /// restore, remote, tmux, and layout transactions can opt out while still
    /// retaining their historical inheritance fallback.
    func resolvedTerminalStartupWorkingDirectory(
        requestedWorkingDirectory: String?,
        sourcePanelId: UUID?,
        allowsDeclarativeDefaults: Bool = true
    ) -> String? {
        if let requested = TerminalWorkingDirectoryResolver.normalized(requestedWorkingDirectory) {
            return requested
        }

        let policy: NewSurfaceWorkingDirectoryPolicy
        let fixedPath: String?
        if allowsDeclarativeDefaults {
            let legacyInheritanceEnabled = settings.value(
                for: settingsCatalog.app.workspaceInheritWorkingDirectory
            )
            let declarative = declarativeTerminalConfigurationCache.snapshot(
                fileURL: declarativeTerminalConfigurationFileURL
            )
            policy = declarative.effectiveWorkingDirectoryPolicy(
                legacyInheritanceEnabled: legacyInheritanceEnabled
            )
            fixedPath = declarative.workingDirectoryPath
        } else {
            policy = .inheritActivePane
            fixedPath = nil
        }

        let sourceHasRemoteDirectoryProvenance = allowsDeclarativeDefaults && (
            isRemoteWorkspace
                || isRemoteTmuxMirror
                || sourcePanelId.map(isRemoteTerminalContext) == true
        )
        let inheritedDirectory: String?
        if policy == .inheritActivePane, !sourceHasRemoteDirectoryProvenance {
            inheritedDirectory = sourcePanelId
                .flatMap { resumedAgentPaneWorkingDirectoryRescue(panelId: $0) }
                ?? TerminalWorkingDirectoryResolver.firstAvailable([
                    sourcePanelId.flatMap { panelDirectories[$0] },
                    sourcePanelId.flatMap { terminalPanel(for: $0)?.requestedWorkingDirectory },
                    currentDirectory,
                ])
        } else {
            inheritedDirectory = nil
        }

        let rootDirectory = TerminalWorkingDirectoryResolver.normalized(workspaceRootDirectory)
            ?? (sourceHasRemoteDirectoryProvenance
                ? nil
                : TerminalWorkingDirectoryResolver.normalized(currentDirectory))
        return WorkspaceCreationWorkingDirectoryPolicy(
            policy: policy,
            fixedPath: fixedPath
        ).resolve(
            explicitWorkingDirectory: requestedWorkingDirectory,
            inheritedWorkingDirectory: inheritedDirectory,
            defaultWorkingDirectory: rootDirectory ?? "/",
            workspaceRootWorkingDirectory: rootDirectory
        )
    }
}
