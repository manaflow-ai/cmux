import CmuxMobileShellModel

extension WorkspaceShellView {
    func createTerminalFromSurfaceGrid(_ workspaceID: MobileWorkspacePreview.ID) {
        guard !isCreatingTerminalFromSurfaceGrid else { return }
        isCreatingTerminalFromSurfaceGrid = true
        pendingCompactCreateNavigationWorkspaceIDs = nil
        Task { @MainActor in
            defer { isCreatingTerminalFromSurfaceGrid = false }
            // The compact grid includes aggregated workspaces from secondary
            // Macs. Foreground the owner before terminal.create uses the live client.
            guard let resolvedWorkspaceID = await store.openWorkspace(workspaceID),
                  store.selectedWorkspaceID == resolvedWorkspaceID,
                  store.workspaces.contains(where: { $0.id == resolvedWorkspaceID }),
                  store.createTerminal(in: resolvedWorkspaceID)
            else { return }
            guard let workspace = store.workspaces.first(where: { $0.id == resolvedWorkspaceID }) else { return }
            browserStore.showNonBrowserSurface(for: workspace.browserSurfaceIdentity)
            compactNavigationPath = [resolvedWorkspaceID]
        }
    }

    func createWorkspaceFromSurfaceGrid() {
        guard !isCreatingWorkspaceFromSurfaceGrid,
              canCreateWorkspaceFromSurfaceGrid else { return }
        let workspaceID = compactSurfaceGridSelectedWorkspaceID
        isCreatingWorkspaceFromSurfaceGrid = true
        Task { @MainActor in
            defer { isCreatingWorkspaceFromSurfaceGrid = false }
            if let workspaceID {
                guard await store.openWorkspace(workspaceID) != nil else { return }
            }
            createWorkspaceInCompactStack()
        }
    }

    var canCreateWorkspaceFromSurfaceGrid: Bool {
        compactSurfaceGridConnectionStatus == .connected && !isCreatingWorkspaceFromSurfaceGrid
    }

    var canCreateTerminal: Bool {
        compactSurfaceGridConnectionStatus == .connected && !isCreatingTerminalFromSurfaceGrid
    }
}
