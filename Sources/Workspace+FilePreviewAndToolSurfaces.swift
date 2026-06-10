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


// MARK: - File preview, sidebar tool, and agent session surfaces
extension Workspace {
    @discardableResult
    func openOrFocusFilePreviewSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool = true
    ) -> FilePreviewPanel? {
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let preview = panel as? FilePreviewPanel else { continue }
            if (preview.filePath as NSString).resolvingSymlinksInPath == canonical {
                if focus {
                    focusPanel(existingId)
                }
                return preview
            }
        }

        return newFilePreviewSurface(inPane: paneId, filePath: filePath, focus: focus)
    }

    @discardableResult
    func openOrFocusFilePreviewSplit(
        from panelId: UUID,
        filePath: String
    ) -> FilePreviewPanel? {
        let canonical = (filePath as NSString).resolvingSymlinksInPath
        for (existingId, panel) in panels {
            guard let preview = panel as? FilePreviewPanel else { continue }
            if (preview.filePath as NSString).resolvingSymlinksInPath == canonical {
                focusPanel(existingId)
                return preview
            }
        }

        if let targetPane = preferredRightSideTargetPane(fromPanelId: panelId) {
            return newFilePreviewSurface(inPane: targetPane, filePath: filePath, focus: true)
        }

        guard let sourcePaneId = paneId(forPanelId: panelId) else { return nil }
        return splitPaneWithFilePreview(
            targetPane: sourcePaneId,
            orientation: .horizontal,
            insertFirst: false,
            filePath: filePath
        )
    }

    @discardableResult
    func newFilePreviewSurface(
        inPane paneId: PaneID,
        filePath: String,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> FilePreviewPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let filePreviewPanel = FilePreviewPanel(workspaceId: id, filePath: filePath)
        panels[filePreviewPanel.id] = filePreviewPanel
        panelTitles[filePreviewPanel.id] = filePreviewPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: filePreviewPanel.displayTitle,
            icon: RenderableSystemSymbol.resolvedSurfaceTabIcon(filePreviewPanel.displayIcon),
            kind: SurfaceKind.filePreview,
            isDirty: filePreviewPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: filePreviewPanel.id)
            panelTitles.removeValue(forKey: filePreviewPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = filePreviewPanel.id
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(filePreviewPanel.id, paneId: paneId, kind: "file_preview", origin: "file_preview_tab", focused: shouldFocusNewTab)
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            filePreviewPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: filePreviewPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installFilePreviewPanelSubscription(filePreviewPanel)
        return filePreviewPanel
    }

    @discardableResult
    func openOrFocusRightSidebarToolSurface(
        inPane paneId: PaneID,
        mode: RightSidebarMode,
        focus: Bool = true
    ) -> RightSidebarToolPanel? {
        guard mode.canOpenAsPane else { return nil }
        for (existingId, panel) in panels {
            guard let toolPanel = panel as? RightSidebarToolPanel,
                  toolPanel.mode == mode else {
                continue
            }
            if focus {
                focusPanel(existingId)
            }
            return toolPanel
        }
        return newRightSidebarToolSurface(inPane: paneId, mode: mode, focus: focus)
    }

    @discardableResult
    func newRightSidebarToolSurface(
        inPane paneId: PaneID,
        mode: RightSidebarMode,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> RightSidebarToolPanel? {
        guard mode.canOpenAsPane else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let toolPanel = RightSidebarToolPanel(workspace: self, mode: mode)
        panels[toolPanel.id] = toolPanel
        panelTitles[toolPanel.id] = toolPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: toolPanel.displayTitle,
            icon: toolPanel.displayIcon,
            kind: SurfaceKind.rightSidebarTool,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: toolPanel.id)
            panelTitles.removeValue(forKey: toolPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = toolPanel.id
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(toolPanel.id, paneId: paneId, kind: "right_sidebar_tool", origin: "right_sidebar_tool_tab", focused: shouldFocusNewTab)

        if shouldFocusNewTab {
            focusPanel(toolPanel.id)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: toolPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return toolPanel
    }

    @discardableResult
    func newAgentSessionSurface(
        inPane paneId: PaneID,
        providerID: AgentSessionProviderID = .codex,
        rendererKind: AgentSessionRendererKind,
        workingDirectory: String? = nil,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> AgentSessionPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView
        let directory = workingDirectory ?? currentDirectory

        let agentPanel = AgentSessionPanel(
            workspaceId: id,
            rendererKind: rendererKind,
            initialProviderID: providerID,
            workingDirectory: directory
        )
        panels[agentPanel.id] = agentPanel
        panelTitles[agentPanel.id] = agentPanel.displayTitle
        if !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panelDirectories[agentPanel.id] = directory
        }

        guard let newTabId = bonsplitController.createTab(
            title: agentPanel.displayTitle,
            icon: agentPanel.displayIcon,
            kind: SurfaceKind.agentSession,
            isDirty: agentPanel.isDirty,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: agentPanel.id)
            panelTitles.removeValue(forKey: agentPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = agentPanel.id
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            agentPanel.id,
            paneId: paneId,
            kind: "agent_session",
            origin: "agent_session_tab",
            focused: shouldFocusNewTab
        )

        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            agentPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: agentPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installAgentSessionPanelSubscription(agentPanel)

        return agentPanel
    }

    @discardableResult
    func splitPaneWithFilePreview(
        targetPane paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        filePath: String
    ) -> FilePreviewPanel? {
        let filePreviewPanel = FilePreviewPanel(workspaceId: id, filePath: filePath)
        panels[filePreviewPanel.id] = filePreviewPanel
        panelTitles[filePreviewPanel.id] = filePreviewPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: filePreviewPanel.displayTitle,
            icon: RenderableSystemSymbol.resolvedSurfaceTabIcon(filePreviewPanel.displayIcon),
            kind: SurfaceKind.filePreview,
            isDirty: filePreviewPanel.isDirty,
            isLoading: false,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = filePreviewPanel.id

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            panels.removeValue(forKey: filePreviewPanel.id)
            panelTitles.removeValue(forKey: filePreviewPanel.id)
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            return nil
        }
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: filePreviewPanel.id, kind: "file_preview", origin: "file_preview_split", focused: true)

        bonsplitController.selectTab(newTab.id)
        filePreviewPanel.focus()
        installFilePreviewPanelSubscription(filePreviewPanel)
        return filePreviewPanel
    }

}
