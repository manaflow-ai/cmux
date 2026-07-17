#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileChanges
import CmuxMobileShell

extension MobileShellComposite {
    /// Creates a revision- and path-scoped loader for one workspace change.
    ///
    /// A rename's old path is selected only for the base revision. The loader's
    /// cache namespace includes workspace, revision, and resolved path so base
    /// and current bytes can never collide.
    ///
    /// - Parameters:
    ///   - workspaceID: Mac-local workspace identifier.
    ///   - path: Current repository-relative path.
    ///   - oldPath: Previous repository-relative path for a rename.
    ///   - revision: Revision selected by the binary diff card.
    /// - Returns: Closure-backed loader for ``ChatArtifactViewerDestination``.
    public func workspaceChangesArtifactLoader(
        workspaceID: String,
        path: String,
        oldPath: String?,
        revision: FileDiffPreviewRevision
    ) -> ChatArtifactLoader {
        let resolvedPath = revision == .base ? (oldPath ?? path) : path
        let shellRevision: WorkspaceChangesFileRevision = switch revision {
        case .current: .current
        case .base: .base
        }
        return ChatArtifactLoader(
            supportsArtifacts: true,
            supportsDirectoryBrowsing: false,
            scope: .workspaceChanges(
                workspaceID: workspaceID,
                revision: revision.rawValue,
                path: resolvedPath
            ),
            stat: { requestedPath in
                try await self.workspaceChangesFileStat(
                    workspaceID: workspaceID,
                    path: requestedPath,
                    revision: shellRevision
                )
            },
            fetch: { requestedPath, progress in
                try await self.workspaceChangesFileData(
                    workspaceID: workspaceID,
                    path: requestedPath,
                    revision: shellRevision,
                    progress: progress
                )
            },
            stream: { requestedPath, onChunk in
                try await self.streamWorkspaceChangesFile(
                    workspaceID: workspaceID,
                    path: requestedPath,
                    revision: shellRevision,
                    onChunk: onChunk
                )
            }
        )
    }
}
#endif
