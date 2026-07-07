import Bonsplit
import Foundation

extension Workspace {
    @discardableResult
    func newBrowserFileSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> BrowserPanel? {
        guard let fileURL = LocalFileSurfaceRouting.browserFileURL(forFilePath: filePath) else {
            return nil
        }

        let browserPanel = newBrowserSurface(
            inPane: paneId,
            url: fileURL,
            focus: focus,
            creationPolicy: .automationPreload
        )
        if let browserPanel, let targetIndex {
            _ = reorderSurface(panelId: browserPanel.id, toIndex: targetIndex, focus: focus ?? true)
        }
        return browserPanel
    }

    @discardableResult
    func openOrFocusBrowserFileSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool = true
    ) -> BrowserPanel? {
        guard let fileURL = LocalFileSurfaceRouting.browserFileURL(forFilePath: filePath) else {
            return nil
        }
        let canonicalPath = fileURL.standardizedFileURL.path

        for (existingId, panel) in panels {
            guard let browserPanel = panel as? BrowserPanel,
                  browserPanel.currentURLForTabDuplication?.standardizedFileURL.path == canonicalPath else {
                continue
            }
            if focus {
                focusPanel(existingId)
            }
            return browserPanel
        }

        return newBrowserFileSurface(inPane: paneId, filePath: filePath, focus: focus)
    }

    @discardableResult
    func openOrFocusProjectSurface(
        inPane paneId: PaneID,
        projectPath: String,
        focus: Bool = true
    ) -> ProjectPanel? {
        let canonicalPath = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        for (existingId, panel) in panels {
            guard let projectPanel = panel as? ProjectPanel,
                  projectPanel.projectURL.resolvingSymlinksInPath().standardizedFileURL.path == canonicalPath else {
                continue
            }
            if focus {
                focusPanel(existingId)
            }
            return projectPanel
        }

        return newProjectSurface(inPane: paneId, projectPath: projectPath, focus: focus)
    }

    @discardableResult
    func splitPaneWithProject(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        projectPath: String
    ) -> ProjectPanel? {
        guard !projectPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath).standardizedFileURL
        let projectPanel = ProjectPanel(projectURL: url)
        panels[projectPanel.id] = projectPanel
        panelTitles[projectPanel.id] = projectPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: projectPanel.displayTitle,
            icon: projectPanel.displayIcon,
            kind: "project",
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: projectPanel.id)

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) else {
            panels.removeValue(forKey: projectPanel.id)
            panelTitles.removeValue(forKey: projectPanel.id)
            removeSurfaceMapping(forSurfaceId: newTab.id)
            return nil
        }

        publishCmuxSplitCreated(
            newPaneId,
            sourcePaneId: paneId,
            orientation: orientation,
            surfaceId: projectPanel.id,
            kind: "project",
            origin: "project_split",
            focused: true
        )

        bonsplitController.selectTab(newTab.id)
        focusPanel(projectPanel.id)
        projectPanel.reload()
        return projectPanel
    }

    @discardableResult
    func splitPaneWithLocalFile(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> (any Panel)? {
        switch LocalFileSurfaceRouting.kind(forFilePath: filePath) {
        case .project:
            return splitPaneWithProject(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                projectPath: filePath
            )
        case .markdown:
            return splitPaneWithMarkdown(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: filePath
            )
        case .filePreview:
            return splitPaneWithFilePreview(
                targetPane: paneId,
                orientation: orientation,
                insertFirst: insertFirst,
                filePath: filePath
            )
        }
    }

    func localFilePathForPanel(panelId: UUID) -> String? {
        if let filePreviewPanel = filePreviewPanel(for: panelId) {
            return filePreviewPanel.filePath
        }
        if let markdownPanel = panels[panelId] as? MarkdownPanel {
            return markdownPanel.filePath
        }
        return nil
    }

    func browserFileURLForPanel(panelId: UUID) -> URL? {
        guard panels[panelId]?.isDirty == false,
              let filePath = localFilePathForPanel(panelId: panelId) else {
            return nil
        }
        return LocalFileSurfaceRouting.browserFileURL(forFilePath: filePath)
    }

    func openLocalFilePanelInBrowserToRight(panelId: UUID, focus: Bool = true) -> BrowserPanel? {
        guard browserFileURLForPanel(panelId: panelId) != nil,
              let filePath = localFilePathForPanel(panelId: panelId),
              let anchorTabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else {
            return nil
        }

        let targetIndex = browserInsertionIndexToRight(of: anchorTabId, inPane: paneId)
        return newBrowserFileSurface(
            inPane: paneId,
            filePath: filePath,
            focus: focus,
            targetIndex: targetIndex
        )
    }

    private func browserInsertionIndexToRight(of anchorTabId: TabID, inPane paneId: PaneID) -> Int {
        let tabs = bonsplitController.tabs(inPane: paneId)
        guard let anchorIndex = tabs.firstIndex(where: { $0.id == anchorTabId }) else { return tabs.count }
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if let panelId = panelIdFromSurfaceId(tab.id), pinnedPanelIds.contains(panelId) {
                count += 1
            }
        }
        let rawTarget = min(anchorIndex + 1, tabs.count)
        return max(rawTarget, pinnedCount)
    }
}
