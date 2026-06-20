import AppKit
import Bonsplit

extension DockSplitStore {
    func noteKeyboardFocusIntent(window: NSWindow?) {
        AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: .dock, in: window)
    }

    func focusedDockPaneSelection() -> (pane: PaneID?, tab: TabID?) {
        let pane = bonsplitController.focusedPaneId
        return (pane, pane.flatMap { bonsplitController.selectedTab(inPane: $0)?.id })
    }

    func restoreDockPaneSelection(_ selection: (pane: PaneID?, tab: TabID?)?) {
        guard let selection else { return }
        if let tab = selection.tab {
            bonsplitController.selectTab(tab)
        } else if let pane = selection.pane {
            bonsplitController.focusPane(pane)
        }
    }

    /// Creates a new surface in the currently focused Dock pane (Dock toolbar "+" menu).
    func newInFocusedPane(kind: DockSurfaceKind) {
        ensureLoaded()
        guard let paneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else { return }
        _ = newSurface(kind: kind, inPane: paneId, focus: true)
    }

    func collapseToSingleEmptyPane() {
        guard let rootPane = bonsplitController.allPaneIds.first else { return }
        for paneId in bonsplitController.allPaneIds where paneId != rootPane {
            _ = bonsplitController.closePane(paneId)
        }
        bonsplitController.focusPane(rootPane)
    }

    func applyVisibility(to panel: any Panel) {
        if let terminal = panel as? TerminalPanel {
            if isVisibleInUI {
                terminal.hostedView.setVisibleInUI(true)
                TerminalWindowPortalRegistry.updateEntryVisibility(for: terminal.hostedView, visibleInUI: true)
            } else {
                terminal.unfocus()
                terminal.hostedView.setVisibleInUI(false)
                TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
            }
        } else if !isVisibleInUI, let browser = panel as? BrowserPanel {
            browser.unfocus()
            browser.hideBrowserPortalView(source: "dockHidden")
        }
    }
}
