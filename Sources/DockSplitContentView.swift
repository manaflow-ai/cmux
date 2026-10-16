import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import Foundation
import SwiftUI

/// Renders the Dock's Bonsplit tree, reusing `PanelContentView` so Dock
/// terminals and browsers render identically to main-area panes.
struct DockSplitContentView: View {
    let store: DockSplitStore
    let appearance: PanelAppearance
    let appearanceRevision: UInt
    let windowAppearance: WindowAppearanceSnapshot
    let rightSidebarOwnsInputFocus: Bool
    let unreadPanelIDs: Set<UUID>

    var body: some View {
        BonsplitView(controller: store.bonsplitController) { tab, paneId in
            dockContent(tab: tab, paneId: paneId)
        } emptyPane: { paneId in
            dockEmptyPaneView(paneId: paneId)
        }
    }

    func panelView(panel: any Panel, tabID: TabID, paneID: PaneID) -> DockSplitPanelContentView {
        DockSplitPanelContentView(
            store: store,
            panel: panel,
            tabID: tabID,
            paneID: paneID,
            appearance: appearance,
            appearanceRevision: appearanceRevision,
            windowAppearance: windowAppearance,
            rightSidebarOwnsInputFocus: rightSidebarOwnsInputFocus,
            hasUnreadNotification: unreadPanelIDs.contains(panel.id) ||
                store.manualUnreadPanelIds.contains(panel.id)
        )
    }

    @ViewBuilder
    private func dockContent(tab: Bonsplit.Tab, paneId: PaneID) -> some View {
        if let panel = store.panel(for: tab.id) {
            panelView(panel: panel, tabID: tab.id, paneID: paneId)
                .equatable()
                .onTapGesture {
                    store.focusPaneFromDockInteraction(
                        paneId,
                        window: NSApp.keyWindow ?? NSApp.mainWindow
                    )
                }
        } else {
            dockEmptyPaneView(paneId: paneId)
        }
    }

    private func dockEmptyPaneView(paneId: PaneID) -> some View {
        DockEmptyPaneView(
            onNewTerminal: {
                _ = store.newSurfaceFromDockAffordance(
                    kind: .terminal,
                    inPane: paneId,
                    window: NSApp.keyWindow ?? NSApp.mainWindow
                )
            },
            onNewBrowser: {
                _ = store.newSurfaceFromDockAffordance(
                    kind: .browser,
                    inPane: paneId,
                    window: NSApp.keyWindow ?? NSApp.mainWindow
                )
            }
        )
        .onTapGesture {
            store.focusPaneFromDockInteraction(
                paneId,
                window: NSApp.keyWindow ?? NSApp.mainWindow
            )
        }
    }
}
