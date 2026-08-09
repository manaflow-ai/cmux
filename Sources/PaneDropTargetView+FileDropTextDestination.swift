import AppKit
import Bonsplit
import Foundation

/// The behavior boundary for a pane-level drop target. Main-area panes and Dock
/// panes have separate Bonsplit trees, panel registries, and focus transactions;
/// the drop view routes through this owner instead of assuming every pane lives
/// in a `Workspace`.
@MainActor
protocol PaneDropContainer: AnyObject {
    func selectedPanelForPaneDrop(
        in paneId: PaneID
    ) -> (panelId: UUID, panel: any Panel)?

    func canPerformPortalPaneDrop(_ transfer: PaneDragTransfer) -> Bool

    func portalPaneDropZone(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        proposedZone: DropZone
    ) -> DropZone

    func performPortalPaneDrop(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        zone: DropZone
    ) -> Bool

    func simulatorFileDropOperation(
        urls: [URL],
        panelId: UUID
    ) -> NSDragOperation?

    func performSimulatorFileDrop(
        urls: [URL],
        panelId: UUID
    ) -> Bool?

    func handleExternalFileDrop(
        _ request: BonsplitController.ExternalFileDropRequest
    ) -> Bool

    func focusPanelAfterSuccessfulPaneDrop(
        panelId: UUID,
        focusIntent: PanelFocusIntent,
        window: NSWindow?
    )
}

extension PaneDropContainer {
    func canPerformPortalPaneDrop(_ transfer: PaneDragTransfer) -> Bool {
        transfer.isFromCurrentProcess
    }

    func simulatorFileDropOperation(
        urls _: [URL],
        panelId _: UUID
    ) -> NSDragOperation? {
        nil
    }

    func performSimulatorFileDrop(
        urls _: [URL],
        panelId _: UUID
    ) -> Bool? {
        nil
    }

    func fileDropTextDestinationKind(
        in paneId: PaneID,
        hasHostedTerminal: Bool
    ) -> FileDropTextDestinationKind? {
        if hasHostedTerminal { return .terminal }
        guard let selected = selectedPanelForPaneDrop(in: paneId) else {
            return nil
        }

        switch selected.panel.panelType {
        case .terminal:
            return .terminal
        case .filePreview:
            guard let filePreviewPanel = selected.panel as? FilePreviewPanel,
                  filePreviewPanel.previewMode == .text else {
                return nil
            }
            return .editor
        case .browser, .markdown, .rightSidebarTool, .customSidebar, .simulator,
             .agentSession, .project, .extensionBrowser, .workspaceTodo,
             .notifications, .cloudVMLoading, .mobilePairing, .accountSignIn:
            return nil
        }
    }

    func performFileDropAsText(
        _ urls: [URL],
        context: PaneDropContext,
        hostedView: GhosttySurfaceScrollView?,
        window: NSWindow?
    ) -> Bool {
        if let hostedView {
            return FileDropTextDropController.performTerminalFileDrop(
                container: self,
                panelId: context.panelId,
                hostedView: hostedView,
                urls: urls,
                window: window
            )
        }

        guard let selected = selectedPanelForPaneDrop(in: context.paneId) else {
            return false
        }
        if let terminalPanel = selected.panel as? TerminalPanel {
            return FileDropTextDropController.performTerminalFileDrop(
                container: self,
                panelId: selected.panelId,
                hostedView: terminalPanel.hostedView,
                urls: urls,
                window: window ?? terminalPanel.surface.uiWindow
            )
        }
        if let filePreviewPanel = selected.panel as? FilePreviewPanel {
            return FileDropTextDropController.performPanelTextDrop(
                container: self,
                panelId: selected.panelId,
                focusIntent: .filePreview(.textEditor),
                window: window,
                insert: {
                    filePreviewPanel.handleDroppedFileURLsAsText(urls)
                }
            )
        }
        return false
    }
}

extension Workspace: PaneDropContainer {
    func selectedPanelForPaneDrop(
        in paneId: PaneID
    ) -> (panelId: UUID, panel: any Panel)? {
        guard let tabId = bonsplitController.selectedTab(inPane: paneId)?.id,
              let panelId = panelIdFromSurfaceId(tabId),
              let panel = panels[panelId] else {
            return nil
        }
        return (panelId, panel)
    }

    func simulatorFileDropOperation(
        urls: [URL],
        panelId: UUID
    ) -> NSDragOperation? {
        PaneDropTargetView.simulatorFileDropOperation(
            urls: urls,
            workspace: self,
            panelId: panelId
        )
    }

    func performSimulatorFileDrop(
        urls: [URL],
        panelId: UUID
    ) -> Bool? {
        handleSimulatorExternalFileDrop(urls: urls, panelId: panelId)
    }

    func focusPanelAfterSuccessfulPaneDrop(
        panelId: UUID,
        focusIntent: PanelFocusIntent,
        window: NSWindow?
    ) {
        AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
            workspaceId: id,
            panelId: panelId,
            in: window
        )
        focusPanel(panelId, focusIntent: focusIntent)
        _ = panels[panelId]?.restoreFocusIntent(focusIntent)
    }
}

extension DockSplitStore: PaneDropContainer {
    func selectedPanelForPaneDrop(
        in paneId: PaneID
    ) -> (panelId: UUID, panel: any Panel)? {
        guard let tabId = bonsplitController.selectedTab(inPane: paneId)?.id,
              let panelId = surfaceIdToPanelId[tabId],
              let panel = panels[panelId] else {
            return nil
        }
        return (panelId, panel)
    }

    func canPerformPortalPaneDrop(_ transfer: PaneDragTransfer) -> Bool {
        if containsPane(transfer.sourcePaneId) { return true }
        return AppDelegate.shared?.canMoveSurfaceIntoDock(
            sourceTabId: transfer.tabId,
            destinationDock: self
        ) == true
    }

    func focusPanelAfterSuccessfulPaneDrop(
        panelId: UUID,
        focusIntent: PanelFocusIntent,
        window: NSWindow?
    ) {
        focusPanelFromDockInteraction(panelId, window: window)
        _ = panels[panelId]?.restoreFocusIntent(focusIntent)
    }
}

extension AppDelegate {
    func paneDropContainer(
        for context: PaneDropContext
    ) -> (any PaneDropContainer)? {
        if let dock = dockForPane(context.paneId) {
            return dock
        }
        guard let workspace = workspaceFor(tabId: context.workspaceId),
              workspace.bonsplitController.allPaneIds.contains(context.paneId) else {
            return nil
        }
        return workspace
    }
}
