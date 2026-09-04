import CmuxAgentChatUI
import CmuxMobileShell

extension WorkspaceDetailView {
    /// Builds the non-browsable loader used by file-backed panel renderers.
    func panelArtifactLoader(workspaceID: String, surfaceID: String) -> ChatArtifactLoader {
        guard let source = store.makeChatEventSource() else {
            return .unsupported(cache: terminalArtifactThumbnailCache)
        }
        return ChatArtifactLoader(
            panelWorkspaceID: workspaceID,
            panelSurfaceID: surfaceID,
            supportsArtifacts: source.supportsPanelArtifacts,
            cache: terminalArtifactThumbnailCache,
            stat: { path in
                try await source.panelArtifactStat(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path
                )
            },
            fetch: { path, progress in
                try await source.panelArtifactFetch(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    progress: progress
                )
            },
            stream: { path, onChunk in
                try await source.panelArtifactFetch(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    onChunk: onChunk
                )
            },
            thumbnail: { path, maxDimension in
                try await source.panelArtifactThumbnail(
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    path: path,
                    maxDimension: maxDimension
                )
            }
        )
    }
}
