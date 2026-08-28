import AppKit
import Bonsplit
import Foundation

/// The behavior boundary for a pane-level drop target. Main-area panes and Dock
/// panes have separate Bonsplit trees, panel registries, and focus transactions;
/// the drop view routes through this owner instead of assuming every pane lives
/// in a `Workspace`.
@MainActor
protocol PaneDropContainer: AnyObject {
    /// Returns the selected panel owned by `paneId`.
    func selectedPanelForPaneDrop(
        in paneId: PaneID
    ) -> (panelId: UUID, panel: any Panel)?

    /// Returns whether this container can move the resolved live surface.
    func canPerformPortalSurfaceDrop(_ transfer: PaneDragTransfer) -> Bool

    /// Resolves the effective target zone for a portal transfer.
    func portalPaneDropZone(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        proposedZone: DropZone
    ) -> DropZone

    /// Performs a live surface transfer within or into this container.
    func performPortalSurfaceDrop(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        zone: DropZone
    ) -> Bool

    /// Creates the terminal represented by a Vault entry at this destination.
    func performPortalVaultSessionDrop(
        entry: SessionEntry,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool

    /// Attaches to the multiplexer session represented by a Harbor row at
    /// this destination.
    func performPortalHarborSessionDrop(
        session: HarborSession,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool

    /// Projects a Cloud tree row (one resource, or a workspace's collection) at this destination.
    func performPortalSurfaceResourceDrop(
        group: SurfaceResourceGroup,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool

    /// Returns the drag operation for a simulator file destination, if present.
    func simulatorFileDropOperation(
        urls: [URL],
        panelId: UUID
    ) -> NSDragOperation?

    /// Performs a simulator file drop, or returns `nil` for non-simulator panels.
    func performSimulatorFileDrop(
        urls: [URL],
        panelId: UUID
    ) -> Bool?

    /// Opens external files within this container's split tree.
    func handleExternalFileDrop(
        _ request: BonsplitController.ExternalFileDropRequest
    ) -> Bool

    /// Restores container-owned focus after a successful text drop.
    func focusPanelAfterSuccessfulPaneDrop(
        panelId: UUID,
        focusIntent: PanelFocusIntent,
        window: NSWindow?
    )
}

extension PaneDropContainer {
    /// Handles synthetic capabilities before the caller's normal surface move.
    ///
    /// Returning `nil` means the transfer is a live Bonsplit surface. A non-nil
    /// result is authoritative even when handling fails, so a Vault id can never
    /// fall through and be mistaken for a movable surface.
    func performRegisteredPaneTransferDrop(
        _ request: BonsplitController.ExternalTabDropRequest,
        sourceResolver: PaneTransferSourceResolver = PaneTransferSourceResolver()
    ) -> Bool? {
        let id = request.tabId.uuid
        guard let source = sourceResolver.registeredSource(id: id) else {
            return nil
        }

        let handled: Bool
        switch source {
        case .vaultSession(let entry):
            handled = performPortalVaultSessionDrop(
                entry: entry,
                destination: request.destination
            )
        case .filePreview(let entry):
            handled = handleExternalFileDrop(
                BonsplitController.ExternalFileDropRequest(
                    urls: [URL(fileURLWithPath: entry.filePath)],
                    destination: request.destination
                )
            )
        case .surfaceResources(let group):
            handled = performPortalSurfaceResourceDrop(group: group, destination: request.destination)
        case .harborSession(let session):
            handled = performPortalHarborSessionDrop(session: session, destination: request.destination)
        case .surface:
            return nil
        }
        if handled {
            sourceResolver.finish(source, id: id)
        }
        return handled
    }

    /// Applies one acceptance matrix to every pane owner and target kind.
    func canPerformPortalPaneDrop(
        _ transfer: PaneDragTransfer,
        source: PaneTransferSourceResolver.Source
    ) -> Bool {
        switch source {
        case .vaultSession, .filePreview, .surfaceResources, .harborSession:
            return true
        case .surface:
            return canPerformPortalSurfaceDrop(transfer)
        }
    }

    /// Dispatches every resolved source through the same destination mapping.
    func performPortalPaneDrop(
        tabId: UUID,
        sourcePaneId: UUID,
        targetPane paneId: PaneID,
        zone: DropZone,
        source: PaneTransferSourceResolver.Source
    ) -> Bool {
        let destination = PaneDropRouting.destination(
            targetPane: paneId,
            zone: zone
        )
        switch source {
        case .vaultSession(let entry):
            return performPortalVaultSessionDrop(
                entry: entry,
                destination: destination
            )
        case .filePreview(let entry):
            return handleExternalFileDrop(BonsplitController.ExternalFileDropRequest(
                urls: [URL(fileURLWithPath: entry.filePath)],
                destination: destination
            ))
        case .surfaceResources(let group):
            return performPortalSurfaceResourceDrop(group: group, destination: destination)
        case .harborSession(let session):
            return performPortalHarborSessionDrop(session: session, destination: destination)
        case .surface:
            return performPortalSurfaceDrop(
                tabId: tabId,
                sourcePaneId: sourcePaneId,
                targetPane: paneId,
                zone: zone
            )
        }
    }

    /// Declines simulator routing for containers without simulator panels.
    func simulatorFileDropOperation(
        urls _: [URL],
        panelId _: UUID
    ) -> NSDragOperation? {
        nil
    }

    /// Declines Cloud rows for containers that cannot host a projected surface (the Dock).
    func performPortalSurfaceResourceDrop(
        group _: SurfaceResourceGroup,
        destination _: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        false
    }

    /// Declines Harbor rows for containers that cannot host a terminal pane (the Dock).
    func performPortalHarborSessionDrop(
        session _: HarborSession,
        destination _: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        false
    }

    /// Declines simulator handling for containers without simulator panels.
    func performSimulatorFileDrop(
        urls _: [URL],
        panelId _: UUID
    ) -> Bool? {
        nil
    }

    /// Inserts text and applies the container's focus transaction on success.
    @discardableResult
    func performPanelTextDrop(
        panelId: UUID,
        focusIntent: PanelFocusIntent,
        window: NSWindow?,
        insert: () -> Bool
    ) -> Bool {
        guard insert() else { return false }
        focusPanelAfterSuccessfulPaneDrop(
            panelId: panelId,
            focusIntent: focusIntent,
            window: window
        )
        return true
    }

    /// Resolves whether the target pane accepts dropped files as text.
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

    /// Inserts dropped file paths into the target terminal or text editor.
    func performFileDropAsText(
        _ urls: [URL],
        context: PaneDropContext,
        hostedView: GhosttySurfaceScrollView?,
        window: NSWindow?
    ) -> Bool {
        if let hostedView {
            return performPanelTextDrop(
                panelId: context.panelId,
                focusIntent: .terminal(.surface),
                window: window,
                insert: {
                    hostedView.handleDroppedURLs(urls)
                }
            )
        }

        guard let selected = selectedPanelForPaneDrop(in: context.paneId) else {
            return false
        }
        if let terminalPanel = selected.panel as? TerminalPanel {
            return performPanelTextDrop(
                panelId: selected.panelId,
                focusIntent: .terminal(.surface),
                window: window ?? terminalPanel.surface.uiWindow,
                insert: {
                    terminalPanel.hostedView.handleDroppedURLs(urls)
                }
            )
        }
        if let filePreviewPanel = selected.panel as? FilePreviewPanel {
            return performPanelTextDrop(
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
    /// A live surface can always ask the workspace dispatcher to move it.
    func canPerformPortalSurfaceDrop(_: PaneDragTransfer) -> Bool {
        true
    }

    /// Uses the same restore-aware launch as every existing workspace Vault drop.
    func performPortalVaultSessionDrop(
        entry: SessionEntry,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        handleSessionDrop(entry: entry, destination: destination)
    }

    /// Attaches a dropped Harbor row through the manual-IO daemon path.
    func performPortalHarborSessionDrop(
        session: HarborSession,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        handleHarborSessionDrop(session: session, destination: destination)
    }

    /// Projects a dragged Cloud row through the surface catalog.
    func performPortalSurfaceResourceDrop(
        group: SurfaceResourceGroup,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        handleSurfaceResourceDrop(group: group, destination: destination)
    }

    /// Returns the workspace panel selected in the target pane.
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

    /// Delegates simulator drag validation to the workspace policy.
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

    /// Delegates simulator file handling to the workspace.
    func performSimulatorFileDrop(
        urls: [URL],
        panelId: UUID
    ) -> Bool? {
        handleSimulatorExternalFileDrop(urls: urls, panelId: panelId)
    }

    /// Applies workspace focus intent after inserting dropped text.
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
    /// Returns the Dock panel selected in the target pane.
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

    /// Accepts Dock-local surfaces and valid surfaces from another container.
    func canPerformPortalSurfaceDrop(_ transfer: PaneDragTransfer) -> Bool {
        if containsPane(transfer.sourcePaneId) { return true }
        return AppDelegate.shared?.canMoveSurfaceIntoDock(
            sourceTabId: transfer.tabId,
            destinationDock: self
        ) == true
    }

    /// Applies the Dock focus transaction after inserting dropped text.
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
    /// Resolves the workspace or Dock that authoritatively owns a drop target.
    func paneDropContainer(
        for context: PaneDropContext
    ) -> (any PaneDropContainer)? {
        if let dock = DockSplitStore.liveStore(containingPanel: context.panelId),
           let surfaceId = dock.surfaceId(forPanelId: context.panelId),
           dock.bonsplitController.paneId(containing: surfaceId) == context.paneId {
            return dock
        }
        guard let workspace = workspaceFor(tabId: context.workspaceId),
              let surfaceId = workspace.surfaceIdFromPanelId(context.panelId),
              workspace.bonsplitController.paneId(containing: surfaceId) == context.paneId else {
            return nil
        }
        return workspace
    }
}
