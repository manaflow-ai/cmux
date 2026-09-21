import CmuxAgentChatUI
import CmuxMobileShell

extension WorkspaceDetailView {
    /// Stable identity for the background panel warmup. Include every
    /// advertised file descriptor and the connection generation so a rewritten
    /// tab or reconnect cancels the old work before it can populate a new
    /// source's cache namespace.
    var panelArtifactPrefetchIdentity: String {
        let descriptors = workspace.surfaces
            .filter { ($0.kind == .filePreview || $0.kind == .markdown) && $0.filePath != nil }
            .map { surface in
                "\(surface.id.rawValue)\u{1F}\(surface.kind.rawValue)\u{1F}\(surface.title)\u{1F}\(surface.filePath ?? "")"
            }
            .joined(separator: "\u{1E}")
        return "\(workspace.rpcWorkspaceID.rawValue)\u{1E}\(store.artifactSourceIdentity)\u{1E}\(descriptors)"
    }

    /// Warms inactive file-backed workspace surfaces while the selected tab is
    /// being used. The loader's bounded content cache makes each later tab
    /// switch replay local bytes instead of starting a second Mac transfer.
    func prefetchPanelArtifacts() async {
        guard store.selectedWorkspaceID == workspace.id,
              store.supportsPanelArtifacts(in: workspace.id),
              let source = store.makeChatEventSource() else { return }

        let workspaceID = workspace.rpcWorkspaceID.rawValue
        let selectedSurfaceID = store.selectedMacSurfaceID
        let targets = workspace.surfaces.compactMap { surface -> (String, String)? in
            guard (surface.kind == .filePreview || surface.kind == .markdown),
                  let path = surface.filePath,
                  !path.isEmpty,
                  surface.id != selectedSurfaceID else { return nil }
            return (surface.id.rawValue, path)
        }
        guard !targets.isEmpty else { return }

        let contentCache = terminalArtifactContentCache
        let thumbnailCache = terminalArtifactThumbnailCache
        let sourceIdentity = store.artifactSourceIdentity
        let loaders = targets.map { surfaceID, _ in
            ChatArtifactLoader(
                panelWorkspaceID: workspaceID,
                panelSurfaceID: surfaceID,
                supportsArtifacts: source.supportsPanelArtifacts,
                sourceIdentity: sourceIdentity,
                cache: thumbnailCache,
                contentCache: contentCache,
                diagnosticLog: store.diagnosticLog,
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

        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for (index, loader) in loaders.enumerated() {
                guard !Task.isCancelled else { return }
                if running == 2 {
                    _ = await group.next()
                    running -= 1
                }
                let path = targets[index].1
                group.addTask {
                    _ = await loader.prefetch(path: path)
                }
                running += 1
            }
            while running > 0 {
                _ = await group.next()
                running -= 1
            }
        }
    }

    /// Builds the non-browsable loader used by file-backed panel renderers.
    func panelArtifactLoader(workspaceID: String, surfaceID: String) -> ChatArtifactLoader {
        guard let source = store.makeChatEventSource() else {
            return .unsupported(
                cache: terminalArtifactThumbnailCache,
                contentCache: terminalArtifactContentCache,
                diagnosticLog: store.diagnosticLog,
                sourceIdentity: store.artifactSourceIdentity
            )
        }
        return ChatArtifactLoader(
            panelWorkspaceID: workspaceID,
            panelSurfaceID: surfaceID,
            supportsArtifacts: source.supportsPanelArtifacts,
            sourceIdentity: store.artifactSourceIdentity,
            cache: terminalArtifactThumbnailCache,
            contentCache: terminalArtifactContentCache,
            diagnosticLog: store.diagnosticLog,
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
