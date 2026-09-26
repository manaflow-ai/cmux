import Foundation

extension AppSessionSnapshot {
    func restoringPipSurfacesAsWorkspaceTabs() -> AppSessionSnapshot {
        var copy = self
        // Apply the restore window cap before merging detached surfaces. A PiP
        // surface whose recorded home window was beyond the cap must fall back
        // into a surviving workspace rather than being discarded with that
        // window.
        copy.windows = Array(copy.windows.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot))
        guard let pipSurfaces, !pipSurfaces.isEmpty else { return copy }
        if copy.windows.isEmpty {
            copy.windows = [Self.fallbackWindowSnapshot(for: pipSurfaces)]
        }
        var workspaceLocations: [UUID: (windowIndex: Int, workspaceIndex: Int)] = [:]
        for windowIndex in copy.windows.indices {
            for workspaceIndex in copy.windows[windowIndex].tabManager.workspaces.indices {
                guard let workspaceId = copy.windows[windowIndex].tabManager.workspaces[workspaceIndex].workspaceId else {
                    continue
                }
                workspaceLocations[workspaceId] = (windowIndex, workspaceIndex)
            }
        }
        for pipSurface in pipSurfaces {
            if let location = workspaceLocations[pipSurface.homeWorkspaceId] {
                copy.windows[location.windowIndex].tabManager.workspaces[location.workspaceIndex]
                    .appendPipSurfaceIfNeeded(pipSurface.panel)
            } else {
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

    private mutating func insertPipSurfaceIntoSelectedWorkspace(_ pipSurface: SessionPipSurfaceSnapshot) {
        guard let windowIndex = windows.indices.first(where: { !windows[$0].tabManager.workspaces.isEmpty })
            ?? windows.indices.first else { return }
        let workspaceIndex = windows[windowIndex].tabManager.selectedWorkspaceIndex.flatMap {
            windows[windowIndex].tabManager.workspaces.indices.contains($0) ? $0 : nil
        } ?? windows[windowIndex].tabManager.workspaces.indices.first
        if let workspaceIndex {
            windows[windowIndex].tabManager.workspaces[workspaceIndex].appendPipSurfaceIfNeeded(pipSurface.panel)
            return
        }

        let fallback = Self.fallbackWindowSnapshot(for: [pipSurface]).tabManager.workspaces[0]
        windows[windowIndex].tabManager.selectedWorkspaceIndex = 0
        windows[windowIndex].tabManager.workspaces = [fallback]
        windows[windowIndex].tabManager.workspaces[0].appendPipSurfaceIfNeeded(pipSurface.panel)
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
