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

        let remoteWorkspaceOwner = isRemoteWorkspace || isRemoteTmuxMirror
        let sourceHasRemoteDirectoryProvenance = remoteWorkspaceOwner
            || sourcePanelId.map(isRemoteTerminalContext) == true
        // Declarative creation must never copy a remote cwd into a local
        // surface. Respawn/reconnect deliberately opts out of declarative
        // defaults and keeps the historical remote cwd provenance instead.
        let rejectsRemoteDirectoryProvenance = allowsDeclarativeDefaults
            && sourceHasRemoteDirectoryProvenance
        let inheritedDirectory: String?
        if policy == .inheritActivePane, !rejectsRemoteDirectoryProvenance {
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

        let localWorkspaceRoot = remoteWorkspaceOwner
            ? nil
            : TerminalWorkingDirectoryResolver.normalized(workspaceRootDirectory)
        let localCurrentDirectory = remoteWorkspaceOwner
            ? nil
            : TerminalWorkingDirectoryResolver.normalized(currentDirectory)
        let rootDirectory = rejectsRemoteDirectoryProvenance
            ? (localWorkspaceRoot ?? localCurrentDirectory)
            : TerminalWorkingDirectoryResolver.normalized(workspaceRootDirectory)
                ?? TerminalWorkingDirectoryResolver.normalized(currentDirectory)
        return WorkspaceCreationWorkingDirectoryPolicy(
            policy: policy,
            fixedPath: fixedPath
        ).resolve(
            explicitWorkingDirectory: requestedWorkingDirectory,
            inheritedWorkingDirectory: inheritedDirectory,
            defaultWorkingDirectory: rootDirectory
                ?? (remoteWorkspaceOwner
                    ? FileManager.default.homeDirectoryForCurrentUser.path
                    : "/"),
            workspaceRootWorkingDirectory: rootDirectory
        )
    }
}
