import CmuxTerminalCore
import Foundation

struct RemoteTerminalWorkingDirectoryResolution {
    let localWorkingDirectory: String?
    let resolvedWorkingDirectory: String?
    let startupEnvironment: [String: String]
}

extension Workspace {
    /// The directory for an interactive new terminal when Ghostty's matching
    /// `*-inherit-working-directory` key is false (#177), or nil when it
    /// inherits as usual. An explicit directory or a remote startup wins.
    func ghosttyDefaultWorkingDirectoryIfNotInheriting(
        _ kind: KeyPath<GhosttyWorkingDirectoryInheritance, Bool>,
        requestedWorkingDirectory: String?,
        isRemoteStartup: Bool
    ) -> String? {
        guard requestedWorkingDirectory?.isEmpty ?? true, !isRemoteStartup,
              let tabManager = owningTabManager,
              !tabManager.ghosttyWorkingDirectoryInheritance()[keyPath: kind] else {
            return nil
        }
        return tabManager.defaultTerminalWorkingDirectory()
    }

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
