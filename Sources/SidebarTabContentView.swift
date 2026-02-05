import SwiftUI
import Foundation
import Bonsplit

/// View that renders a SidebarTab's content using BonsplitView
struct SidebarTabContentView: View {
    @ObservedObject var sidebarTab: SidebarTab
    let isTabActive: Bool
    @State private var config = GhosttyConfig.load()
    @EnvironmentObject var notificationStore: TerminalNotificationStore

    var body: some View {
        let appearance = PanelAppearance.fromConfig(config)
        let isSplit = sidebarTab.bonsplitController.allPaneIds.count > 1 ||
            sidebarTab.panels.count > 1

        BonsplitView(controller: sidebarTab.bonsplitController) { tab, paneId in
            // Content for each tab in bonsplit
            if let panel = sidebarTab.panel(for: tab.id) {
                let isFocused = isTabActive && sidebarTab.focusedPanelId == panel.id
                PanelContentView(
                    panel: panel,
                    isFocused: isFocused,
                    isSplit: isSplit,
                    appearance: appearance,
                    notificationStore: notificationStore,
                    onFocus: { sidebarTab.focusPanel(panel.id) },
                    onTriggerFlash: { sidebarTab.triggerDebugFlash(panelId: panel.id) }
                )
                .onTapGesture {
                    sidebarTab.bonsplitController.focusPane(paneId)
                }
            } else {
                // Fallback for tabs without panels (shouldn't happen normally)
                EmptyPanelView()
            }
        } emptyPane: { paneId in
            // Empty pane content
            EmptyPanelView()
                .onTapGesture {
                    sidebarTab.bonsplitController.focusPane(paneId)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            config = GhosttyConfig.load()
        }
    }
}

/// View shown for empty panes
struct EmptyPanelView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Empty Panel")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Create a new tab or split")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
