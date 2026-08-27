import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import SwiftUI

/// Isolates one Dock panel behind an immutable render snapshot so unread
/// changes for another keep-alive tab do not update this panel's AppKit host.
struct DockSplitPanelContentView: View, Equatable {
    private struct RenderSnapshot: Equatable {
        let storeID: ObjectIdentifier
        let workspaceID: UUID
        let panelID: UUID
        let panelType: PanelType
        // Deferred browser placeholders and their materialized BrowserPanel share
        // the same panel type and stable ID. Include the implementation state so
        // `.equatable()` rebuilds this slot when WebKit is installed.
        let isDeferredBrowser: Bool
        let tabID: TabID
        let paneID: PaneID
        let rightSidebarOwnsInputFocus: Bool
        let hasUnreadNotification: Bool
        let appearanceRevision: UInt
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.renderSnapshot == rhs.renderSnapshot
    }

    let store: DockSplitStore
    let panel: any Panel
    let tabID: TabID
    let paneID: PaneID
    let appearance: PanelAppearance
    let windowAppearance: WindowAppearanceSnapshot
    let rightSidebarOwnsInputFocus: Bool
    let hasUnreadNotification: Bool

    private let renderSnapshot: RenderSnapshot

    init(
        store: DockSplitStore,
        panel: any Panel,
        tabID: TabID,
        paneID: PaneID,
        appearance: PanelAppearance,
        appearanceRevision: UInt,
        windowAppearance: WindowAppearanceSnapshot,
        rightSidebarOwnsInputFocus: Bool,
        hasUnreadNotification: Bool
    ) {
        self.store = store
        self.panel = panel
        self.tabID = tabID
        self.paneID = paneID
        self.appearance = appearance
        self.windowAppearance = windowAppearance
        self.rightSidebarOwnsInputFocus = rightSidebarOwnsInputFocus
        self.hasUnreadNotification = hasUnreadNotification
        // Dock stores admit terminal/browser panels plus file previews opened by
        // drops; none of those shared branches consume `windowAppearance`, so it
        // is intentionally outside this key.
        renderSnapshot = RenderSnapshot(
            storeID: ObjectIdentifier(store),
            workspaceID: store.workspaceId,
            panelID: panel.id,
            panelType: panel.panelType,
            isDeferredBrowser: panel is DeferredBrowserPanel,
            tabID: tabID,
            paneID: paneID,
            rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus,
            hasUnreadNotification: hasUnreadNotification,
            appearanceRevision: appearanceRevision
        )
    }

    var body: some View {
        panelContentView()
    }

    func panelContentView() -> PanelContentView {
        let isFocused = store.panelIsActiveInVisibleDockPane(panel.id) && rightSidebarOwnsInputFocus
        let isSelectedInPane = store.bonsplitController.selectedTab(inPane: paneID)?.id == tabID
        let isVisibleInUI = store.panelIsSelectedInVisibleDockPane(panel.id)
        let isSplit = store.bonsplitController.allPaneIds.count > 1
        return PanelContentView(
            panel: panel,
            workspaceId: store.workspaceId,
            paneId: paneID,
            isFocused: isFocused,
            isSelectedInPane: isSelectedInPane,
            isVisibleInUI: isVisibleInUI,
            allowsPointerInput: isVisibleInUI,
            portalPriority: 1,
            isSplit: isSplit,
            appearance: appearance,
            windowAppearance: windowAppearance,
            customSidebarTabManager: nil,
            hasUnreadNotification: hasUnreadNotification,
            terminalAgentContext: "",
            paneOwnershipOverride: isVisibleInUI,
            terminalPaneOwnershipResolver: {
                guard store.paneId(forPanelId: panel.id)?.id == paneID.id else { return false }
                return store.panelIsSelectedInVisibleDockPane(panel.id)
            },
            onFocus: {
                store.focusPanelFromDockInteraction(
                    panel.id,
                    window: NSApp.keyWindow ?? NSApp.mainWindow
                )
            },
            onRequestPanelFocus: {
                store.focusPanelFromDockInteraction(
                    panel.id,
                    window: NSApp.keyWindow ?? NSApp.mainWindow
                )
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
}
