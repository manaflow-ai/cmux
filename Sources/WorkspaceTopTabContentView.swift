import SwiftUI
import Foundation
import AppKit
import Bonsplit

struct WorkspaceTopTabContentView: View {
    @ObservedObject var workspace: Workspace
    let topTab: WorkspaceTopTabState
    let isWorkspaceVisible: Bool
    let isWorkspaceInputActive: Bool
    let workspacePortalPriority: Int
    let appearance: PanelAppearance
    @EnvironmentObject var notificationStore: TerminalNotificationStore

    private var isTopTabSelected: Bool {
        workspace.selectedTopTabId == topTab.id
    }

    private var isTopTabVisible: Bool {
        isWorkspaceVisible && isTopTabSelected
    }

    private var isTopTabInputActive: Bool {
        isWorkspaceInputActive && isTopTabSelected
    }

    private var isSplit: Bool {
        topTab.bonsplitController.allPaneIds.count > 1
    }

    private var splitZoomRenderIdentity: String {
        topTab.bonsplitController.zoomedPaneId.map { "zoom:\($0.id.uuidString)" } ?? "unzoomed"
    }

    var body: some View {
        let _ = { topTab.bonsplitController.isInteractive = isTopTabInputActive }()
        let _ = {
            topTab.bonsplitController.onFileDrop = { urls, paneId in
                guard let tabId = topTab.bonsplitController.selectedTab(inPane: paneId)?.id,
                      let panelId = topTab.surfaceIdToPanelId[tabId],
                      let panel = workspace.panels[panelId] as? TerminalPanel else { return false }
                return panel.hostedView.handleDroppedURLs(urls)
            }
        }()

        BonsplitView(controller: topTab.bonsplitController) { tab, paneId in
            if let panelId = topTab.surfaceIdToPanelId[tab.id],
               let panel = workspace.panels[panelId] {
                let isFocused = isTopTabInputActive && workspace.focusedPanelId == panel.id
                let isSelectedInPane = topTab.bonsplitController.selectedTab(inPane: paneId)?.id == tab.id
                let isVisibleInUI = WorkspaceContentView.panelVisibleInUI(
                    isWorkspaceVisible: isTopTabVisible,
                    isSelectedInPane: isSelectedInPane,
                    isFocused: isFocused
                )
                let hasUnreadNotification = Workspace.shouldShowUnreadIndicator(
                    hasUnreadNotification: notificationStore.hasUnreadNotification(forTabId: workspace.id, surfaceId: panel.id),
                    isManuallyUnread: workspace.manualUnreadPanelIds.contains(panel.id)
                )
                PanelContentView(
                    panel: panel,
                    paneId: paneId,
                    isFocused: isFocused,
                    isSelectedInPane: isSelectedInPane,
                    isVisibleInUI: isVisibleInUI,
                    portalPriority: workspacePortalPriority,
                    isSplit: isSplit,
                    appearance: appearance,
                    hasUnreadNotification: hasUnreadNotification,
                    onFocus: {
                        guard isTopTabInputActive else { return }
                        guard workspace.panels[panel.id] != nil else { return }
                        workspace.focusPanel(panel.id, trigger: .terminalFirstResponder)
                    },
                    onRequestPanelFocus: {
                        guard isTopTabInputActive else { return }
                        guard workspace.panels[panel.id] != nil else { return }
                        workspace.focusPanel(panel.id)
                    },
                    onTriggerFlash: { workspace.triggerDebugFlash(panelId: panel.id) }
                )
                .onTapGesture {
                    topTab.bonsplitController.focusPane(paneId)
                }
            } else {
                EmptyPanelView(workspace: workspace, paneId: paneId)
            }
        } emptyPane: { paneId in
            EmptyPanelView(workspace: workspace, paneId: paneId)
                .onTapGesture {
                    topTab.bonsplitController.focusPane(paneId)
                }
        }
        .internalOnlyTabDrag()
        .id("\(topTab.id.uuidString):\(splitZoomRenderIdentity)")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isTopTabSelected ? 1 : 0)
        .allowsHitTesting(isTopTabSelected)
    }
}
