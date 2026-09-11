import Foundation

struct RemoteTerminalWorkingDirectoryResolution {
    let localWorkingDirectory: String?
    let resolvedWorkingDirectory: String?
    let startupEnvironment: [String: String]
}

extension Workspace {
    func resolveRemoteTerminalWorkingDirectory(
        requestedWorkingDirectory: String?,
        sourcePanelId: UUID?,
        startupEnvironment: [String: String],
        explicitRemoteInitialWorkingDirectory: String?,
        isRemoteStartup: Bool,
        inheritWorkingDirectoryFallback: Bool,
        resolveLocalFallback: Bool
    ) -> RemoteTerminalWorkingDirectoryResolution {
        let resolvedWorkingDirectory: String?
        if isRemoteStartup {
            resolvedWorkingDirectory = inheritWorkingDirectoryFallback
                ? resolvedTerminalStartupWorkingDirectory(
                    requestedWorkingDirectory: requestedWorkingDirectory,
                    sourcePanelId: sourcePanelId,
                    preserveExact: true
                )
                : RemoteTerminalWorkingDirectoryResolver.normalized(
                    requestedWorkingDirectory,
                    preserveExact: true
                )
        } else {
            resolvedWorkingDirectory = resolveLocalFallback
                ? resolvedTerminalStartupWorkingDirectory(
                    requestedWorkingDirectory: requestedWorkingDirectory,
                    sourcePanelId: sourcePanelId
                )
                : requestedWorkingDirectory
        }
        guard isRemoteStartup else {
            return RemoteTerminalWorkingDirectoryResolution(
                localWorkingDirectory: resolvedWorkingDirectory,
                resolvedWorkingDirectory: resolvedWorkingDirectory,
                startupEnvironment: startupEnvironment
            )
        }
        var startupEnvironment = startupEnvironment
        startupEnvironment.removeValue(forKey: Self.remoteInitialWorkingDirectoryEnvironmentKey)
        startupEnvironment[Self.remoteInitialWorkingDirectoryEnvironmentKey] =
            resolvedWorkingDirectory ?? explicitRemoteInitialWorkingDirectory
        return RemoteTerminalWorkingDirectoryResolution(
            localWorkingDirectory: nil,
            resolvedWorkingDirectory: resolvedWorkingDirectory,
            startupEnvironment: startupEnvironment
        )
    }
}
