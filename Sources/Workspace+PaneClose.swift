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


// MARK: - Panel close confirmation and teardown
extension Workspace {
    nonisolated static func resolveCloseConfirmation(
        shellActivityState: PanelShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        switch shellActivityState ?? .unknown {
        case .promptIdle:
            return false
        case .commandRunning:
            return true
        case .unknown:
            return fallbackNeedsConfirmClose
        }
    }

    // MARK: - Initialization

    func panelNeedsConfirmClose(panelId: UUID, fallbackNeedsConfirmClose: Bool) -> Bool {
        Self.resolveCloseConfirmation(
            shellActivityState: panelShellActivityStates[panelId],
            fallbackNeedsConfirmClose: fallbackNeedsConfirmClose
        )
    }

    func panelNeedsConfirmClose(panelId: UUID) -> Bool {
        guard let panel = panels[panelId] else { return false }
        if let terminalPanel = panel as? TerminalPanel {
            return panelNeedsConfirmClose(
                panelId: panelId,
                fallbackNeedsConfirmClose: terminalPanel.needsConfirmClose()
            )
        }
        return panel.isDirty
    }

    /// Tear down all panels in this workspace, freeing their Ghostty surfaces.
    /// Called before TabManager removes the workspace so child processes receive SIGHUP even if ARC deallocation is delayed.
    func teardownAllPanels() {
        portalRenderingEnabled = false
        clearLayoutFollowUp()
        hideAllTerminalPortalViews()
        hideAllBrowserPortalViews()
        let panelEntries = Array(panels)
        for (panelId, panel) in panelEntries {
            discardClosedPanelLifecycleState(
                panelId: panelId,
                tabId: surfaceIdFromPanelId(panelId),
                paneId: paneId(forPanelId: panelId),
                panel: panel,
                origin: "workspace_teardown",
                closePanel: true,
                publishSurfaceClosedEvent: true,
                clearSurfaceNotifications: true,
                requestTransferredRemoteCleanup: true,
                cleanupControllerSurfaceState: true
            )
        }
        pruneSurfaceMetadata(validSurfaceIds: [])
        syncRemotePortScanTTYs()
        recomputeListeningPorts()
        clearRemoteConfigurationIfWorkspaceBecameLocal()
        restoredTerminalScrollbackByPanelId.removeAll(keepingCapacity: false)
#if DEBUG
        debugSessionSnapshotScrollbackFallbackPanelIds.removeAll(keepingCapacity: false)
        debugSessionSnapshotSyntheticScrollbackByPanelId.removeAll(keepingCapacity: false)
#endif
        pendingTerminalInputObserversByPanelId.removeAll(keepingCapacity: false)
        terminalInheritanceFontPointsByPanelId.removeAll(keepingCapacity: false)
        lastTerminalConfigInheritancePanelId = nil
        lastTerminalConfigInheritanceFontPoints = nil
    }

    /// Close a panel.
    /// Returns true when a bonsplit tab close request was issued.
    func closePanel(_ panelId: UUID, force: Bool = false) -> Bool {
        if let tabId = surfaceIdFromPanelId(panelId) {
            // Close the tab in bonsplit (this triggers delegate callback)
            return requestCloseTab(tabId, force: force)
        }

        // Mapping can transiently drift during split-tree mutations. If the target panel is
        // currently focused (or is the active terminal first responder), close whichever tab
        // bonsplit marks selected in that focused pane.
        let firstResponderPanelId = cmuxOwningGhosttyView(
            for: NSApp.keyWindow?.firstResponder ?? NSApp.mainWindow?.firstResponder
        )?.terminalSurface?.id
        let targetIsActive = focusedPanelId == panelId || firstResponderPanelId == panelId
        guard targetIsActive,
              let focusedPane = bonsplitController.focusedPaneId,
              let selected = bonsplitController.selectedTab(inPane: focusedPane) else {
#if DEBUG
            cmuxDebugLog(
                "surface.close.fallback.skip panel=\(panelId.uuidString.prefix(5)) " +
                "focusedPanel=\(focusedPanelId?.uuidString.prefix(5) ?? "nil") " +
                "firstResponderPanel=\(firstResponderPanelId?.uuidString.prefix(5) ?? "nil") " +
                "focusedPane=\(bonsplitController.focusedPaneId?.id.uuidString.prefix(5) ?? "nil")"
            )
#endif
            return false
        }

        let closed = requestCloseTab(selected.id, force: force)
#if DEBUG
        cmuxDebugLog(
            "surface.close.fallback panel=\(panelId.uuidString.prefix(5)) " +
            "selectedTab=\(String(describing: selected.id).prefix(5)) " +
            "closed=\(closed ? 1 : 0)"
        )
#endif
        return closed
    }

    func requestCloseTab(_ tabId: TabID, force: Bool) -> Bool {
        if force { forceCloseTabIds.insert(tabId) }
        let closed = bonsplitController.closeTab(tabId); if force && !closed { forceCloseTabIds.remove(tabId) }
        return closed
    }

    /// Check if any panel needs close confirmation
    func needsConfirmClose() -> Bool {
        for (panelId, _) in panels {
            if panelNeedsConfirmClose(panelId: panelId) {
                return true
            }
        }
        return false
    }

}
