import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import SwiftUI

struct SurfacePipHostView: View {
    let panel: any Panel
    let workspaceId: UUID
    let paneId: PaneID
    let onRequestFocus: () -> Void

    @State private var appearanceConfig = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "surfacePip.initial")

    private var appearance: PanelAppearance {
        PanelAppearance.fromConfig(appearanceConfig)
    }

    private var windowAppearance: WindowAppearanceSnapshot {
        AppWindowChromeComposition().appearanceSnapshotFromUserDefaults()
    }

    var body: some View {
        PanelContentView(
            panel: panel,
            workspaceId: workspaceId,
            paneId: paneId,
            isFocused: true,
            isSelectedInPane: true,
            isVisibleInUI: true,
            portalPriority: 10_000,
            isSplit: false,
            appearance: appearance,
            windowAppearance: windowAppearance,
            customSidebarTabManager: nil,
            hasUnreadNotification: false,
            terminalAgentContext: "",
            paneOwnershipOverride: true,
            onFocus: onRequestFocus,
            onRequestPanelFocus: onRequestFocus,
            onResumeAgentHibernation: {},
            onAutoResumeAgentHibernation: {},
            onTriggerFlash: {}
        )
        .background(Color.clear)
        .onAppear {
            refreshAppearance(reason: "onAppear")
            onRequestFocus()
        }
    }

    private func refreshAppearance(reason: String) {
        appearanceConfig = WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "surfacePip.\(reason)")
    }
}
