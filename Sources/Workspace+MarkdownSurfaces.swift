import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Markdown and project surface creation
extension Workspace {
    /// Open the markdown viewer for `filePath`, reusing an existing
    /// `MarkdownPanel` in this workspace that already shows the same file.
    /// Paths are compared after symlink resolution so `./README.md` and a
    /// symlink pointing at the same file focus the same viewer.
    /// Returns `nil` when no existing viewer matches and split creation
    /// fails, so callers can fall back to the preferred editor / system opener.
    @discardableResult
    func openOrFocusMarkdownSplit(
        from panelId: UUID,
        filePath: String
    ) -> MarkdownPanel? {
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let md = panel as? MarkdownPanel else { continue }
            if (md.filePath as NSString).resolvingSymlinksInPath == canonical {
                focusPanel(existingId)
                return md
            }
        }

        if let targetPane = preferredRightSideTargetPane(fromPanelId: panelId) {
            return newMarkdownSurface(inPane: targetPane, filePath: filePath, focus: true)
        }

        return newMarkdownSplit(
            from: panelId,
            orientation: .horizontal,
            insertFirst: false,
            filePath: filePath,
            focus: true
        )
    }

    func newMarkdownSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        filePath: String,
        focus: Bool = true,
        fontSize: Double? = nil
    ) -> MarkdownPanel? {
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath, fontSize: fontSize)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = markdownPanel.id
        let previousFocusedPanelId = focusedPanelId

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: markdownPanel.id, kind: "markdown", origin: "markdown_split", focused: focus)

        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.markdownSplitReparent"
            )
            focusPanel(markdownPanel.id)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    @discardableResult
    func newMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> MarkdownPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = markdownPanel.id
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(markdownPanel.id, paneId: paneId, kind: "markdown", origin: "markdown_tab", focused: shouldFocusNewTab)
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: markdownPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

    @discardableResult
    func newProjectSurface(
        inPane paneId: PaneID,
        projectPath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> ProjectPanel? {
        guard !projectPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath).standardizedFileURL
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let projectPanel = ProjectPanel(projectURL: url)
        panels[projectPanel.id] = projectPanel
        panelTitles[projectPanel.id] = projectPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: projectPanel.displayTitle,
            icon: projectPanel.displayIcon,
            kind: SurfaceKind.project,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: projectPanel.id)
            panelTitles.removeValue(forKey: projectPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = projectPanel.id
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(projectPanel.id, paneId: paneId, kind: SurfaceKind.project, origin: "project_tab", focused: shouldFocusNewTab)
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: projectPanel.id,
                previousHostedView: previousHostedView
            )
        }

        projectPanel.reload()
        return projectPanel
    }

    @discardableResult
    func openOrFocusMarkdownSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool = true
    ) -> MarkdownPanel? {
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let markdownPanel = panel as? MarkdownPanel else { continue }
            if (markdownPanel.filePath as NSString).resolvingSymlinksInPath == canonical {
                if focus {
                    focusPanel(existingId)
                }
                return markdownPanel
            }
        }

        return newMarkdownSurface(inPane: paneId, filePath: filePath, focus: focus)
    }

    @discardableResult
    func splitPaneWithMarkdown(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> MarkdownPanel? {
        let markdownPanel = MarkdownPanel(workspaceId: id, filePath: filePath)
        panels[markdownPanel.id] = markdownPanel
        panelTitles[markdownPanel.id] = markdownPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: markdownPanel.displayTitle,
            icon: markdownPanel.displayIcon,
            kind: SurfaceKind.markdown,
            isDirty: markdownPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = markdownPanel.id

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) != nil else {
            panels.removeValue(forKey: markdownPanel.id)
            panelTitles.removeValue(forKey: markdownPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            return nil
        }

        bonsplitController.selectTab(newTab.id)
        focusPanel(markdownPanel.id)
        installMarkdownPanelSubscription(markdownPanel)
        return markdownPanel
    }

}
