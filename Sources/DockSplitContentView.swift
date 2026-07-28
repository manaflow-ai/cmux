import AppKit
import Bonsplit
import Foundation
import SwiftUI

/// Renders the Dock's Bonsplit tree, reusing `PanelContentView` so Dock
/// terminals and browsers render identically to main-area panes.
struct DockSplitContentView: View {
    let store: DockSplitStore
    let appearance: PanelAppearance
    let windowAppearance: WindowAppearanceSnapshot
    let rightSidebarOwnsInputFocus: Bool
    let unreadPanelIDs: Set<UUID>

    /// Portal z-priority for Dock-hosted terminal/browser surfaces. Kept low so
    /// Dock surfaces never overlay main-area surfaces.
    private static let portalPriority = 1

    var body: some View {
        BonsplitView(controller: store.bonsplitController) { tab, paneId in
            dockContent(tab: tab, paneId: paneId)
        } emptyPane: { paneId in
            DockEmptyPaneView(
                onNewTerminal: { _ = store.newSurface(kind: .terminal, inPane: paneId, focus: true) },
                onNewBrowser: { _ = store.newSurface(kind: .browser, inPane: paneId, focus: true) }
            )
            .onTapGesture { store.bonsplitController.focusPane(paneId) }
        }
    }

    func panelContentView(panel: any Panel, tabID: UUID, paneId: PaneID) -> PanelContentView {
        let isFocused = store.panelIsActiveInVisibleDockPane(panel.id) && rightSidebarOwnsInputFocus
        let isSelectedInPane = store.bonsplitController.selectedTab(inPane: paneId)?.id == tabID
        let isVisibleInUI = store.panelIsSelectedInVisibleDockPane(panel.id)
        let isSplit = store.bonsplitController.allPaneIds.count > 1
        return PanelContentView(
            panel: panel,
            workspaceId: store.workspaceId,
            paneId: paneId,
            isFocused: isFocused,
            isSelectedInPane: isSelectedInPane,
            isVisibleInUI: isVisibleInUI,
            allowsPointerInput: isVisibleInUI,
            portalPriority: Self.portalPriority,
            isSplit: isSplit,
            appearance: appearance,
            windowAppearance: windowAppearance,
            customSidebarTabManager: nil,
            hasUnreadNotification: unreadPanelIDs.contains(panel.id),
            terminalAgentContext: "",
            paneOwnershipOverride: isVisibleInUI,
            terminalPaneOwnershipResolver: {
                guard store.paneId(forPanelId: panel.id)?.id == paneId.id else { return false }
                return store.panelIsSelectedInVisibleDockPane(panel.id)
            },
            onFocus: {
                store.bonsplitController.focusPane(paneId)
                store.noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow)
            },
            onRequestPanelFocus: {
                store.noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow)
                store.focusPanel(panel.id)
            },
            onResumeAgentHibernation: {
                _ = store.resumeAgentHibernation(panelId: panel.id, focus: true)
            },
            onAutoResumeAgentHibernation: {
                _ = store.resumeAgentHibernation(panelId: panel.id, focus: false)
            },
            onTriggerFlash: {}
        )
    }

    @ViewBuilder
    private func dockContent(tab: Bonsplit.Tab, paneId: PaneID) -> some View {
        if let panel = store.panel(for: tab.id) {
            panelContentView(panel: panel, tabID: tab.id, paneId: paneId)
                .onTapGesture { store.bonsplitController.focusPane(paneId) }
        } else {
            DockEmptyPaneView(
                onNewTerminal: { _ = store.newSurface(kind: .terminal, inPane: paneId, focus: true) },
                onNewBrowser: { _ = store.newSurface(kind: .browser, inPane: paneId, focus: true) }
            )
            .onTapGesture { store.bonsplitController.focusPane(paneId) }
        }
    }
}
