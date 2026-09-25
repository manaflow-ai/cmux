import Foundation

extension AppSessionSnapshot {
    func restoringPipSurfacesAsWorkspaceTabs() -> AppSessionSnapshot {
        guard let pipSurfaces, !pipSurfaces.isEmpty else { return self }
        var copy = self
        if copy.windows.isEmpty {
            copy.windows = [Self.fallbackWindowSnapshot(for: pipSurfaces)]
        }
        for pipSurface in pipSurfaces {
            if !copy.insertPipSurfaceAsWorkspaceTab(pipSurface) {
                copy.insertPipSurfaceIntoSelectedWorkspace(pipSurface)
            }
        }
        return copy
    }

    private static func fallbackWindowSnapshot(for pipSurfaces: [SessionPipSurfaceSnapshot]) -> SessionWindowSnapshot {
        let fallbackWorkspace = SessionWorkspaceSnapshot(
            processTitle: String(localized: "surfacePip.window.titleFallback", defaultValue: "Picture in Picture"),
            customTitle: nil,
            customColor: nil,
            isPinned: false,
            currentDirectory: pipSurfaces.first?.panel.directory ?? FileManager.default.homeDirectoryForCurrentUser.path,
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        return SessionWindowSnapshot(
            frame: pipSurfaces.first.map { $0.frame },
            display: nil,
            tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [fallbackWorkspace]),
            sidebar: SessionSidebarSnapshot(
                isVisible: true,
                selection: .tabs,
                width: SessionPersistencePolicy.defaultSidebarWidth
            )
        )
    }

    private mutating func insertPipSurfaceAsWorkspaceTab(_ pipSurface: SessionPipSurfaceSnapshot) -> Bool {
        for windowIndex in windows.indices {
            for workspaceIndex in windows[windowIndex].tabManager.workspaces.indices {
                guard windows[windowIndex].tabManager.workspaces[workspaceIndex].workspaceId == pipSurface.homeWorkspaceId else {
                    continue
                }
                windows[windowIndex].tabManager.workspaces[workspaceIndex].appendPipSurfaceIfNeeded(pipSurface.panel)
                return true
            }
        }
        return false
    }

    private mutating func insertPipSurfaceIntoSelectedWorkspace(_ pipSurface: SessionPipSurfaceSnapshot) {
        guard let windowIndex = windows.indices.first,
              let workspaceIndex = windows[windowIndex].tabManager.selectedWorkspaceIndex.flatMap({
                  windows[windowIndex].tabManager.workspaces.indices.contains($0) ? $0 : nil
              }) ?? windows[windowIndex].tabManager.workspaces.indices.first else {
            return
        }
        windows[windowIndex].tabManager.workspaces[workspaceIndex].appendPipSurfaceIfNeeded(pipSurface.panel)
    }
}

extension SessionWorkspaceSnapshot {
    mutating func appendPipSurfaceIfNeeded(_ panel: SessionPanelSnapshot) {
        guard !panels.contains(where: { $0.id == panel.id }) else { return }
        panels.append(panel)
        layout = layout.appendingPanelToFirstPane(panel.id)
        if focusedPanelId == nil {
            focusedPanelId = panel.id
        }
    }
}

extension SessionWorkspaceLayoutSnapshot {
    func appendingPanelToFirstPane(_ panelId: UUID) -> SessionWorkspaceLayoutSnapshot {
        switch self {
        case .pane(var pane):
            if !pane.panelIds.contains(panelId) {
                pane.panelIds.append(panelId)
            }
            if pane.selectedPanelId == nil {
                pane.selectedPanelId = panelId
            }
            return .pane(pane)
        case .split(var split):
            split.first = split.first.appendingPanelToFirstPane(panelId)
            return .split(split)
        }
    }
}
