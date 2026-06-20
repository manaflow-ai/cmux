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
        if let pane = selection.pane {
            bonsplitController.focusPane(pane)
        }
        if let tab = selection.tab {
            bonsplitController.selectTab(tab)
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

    func panelIsSelectedInVisibleDockPane(_ panelId: UUID) -> Bool {
        guard isVisibleInUI,
              let tabId = surfaceId(forPanelId: panelId),
              let paneId = paneId(forPanelId: panelId) else { return false }
        return bonsplitController.selectedTab(inPane: paneId)?.id == tabId
    }

    func panelIsActiveInVisibleDockPane(_ panelId: UUID) -> Bool {
        isVisibleInUI && focusedPanelId == panelId
    }

    func applyVisibilityToAllPanels() {
        forEachPanel { _, panel in applyVisibility(to: panel) }
    }

    func applyFocusedDockSelection() {
        guard let paneId = bonsplitController.focusedPaneId,
              let tabId = bonsplitController.selectedTab(inPane: paneId)?.id else {
            applyVisibilityToAllPanels()
            return
        }
        applyDockSelection(tabId: tabId, inPane: paneId)
    }

    func applyDockSelection(tabId: TabID, inPane pane: PaneID) {
        applyVisibilityToAllPanels()
        guard isVisibleInUI,
              bonsplitController.focusedPaneId == pane,
              let selectedPanel = panel(for: tabId) else { return }

        let activationIntent = selectedPanel.preferredFocusIntentForActivation()
        selectedPanel.prepareFocusIntentForActivation(activationIntent)
        forEachPanel { panelId, panel in
            if panelId != selectedPanel.id {
                panel.unfocus()
            }
        }
        selectedPanel.focus()
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        applyDockSelection(tabId: tab.id, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        guard let tab = controller.selectedTab(inPane: pane) else {
            applyVisibilityToAllPanels()
            return
        }
        applyDockSelection(tabId: tab.id, inPane: pane)
    }

    func applyVisibility(to panel: any Panel) {
        let shouldBeVisible = panelIsSelectedInVisibleDockPane(panel.id)
        let shouldBeActive = panelIsActiveInVisibleDockPane(panel.id)
        if let terminal = panel as? TerminalPanel {
            if shouldBeVisible {
                terminal.hostedView.setVisibleInUI(true)
                terminal.hostedView.setActive(shouldBeActive)
                TerminalWindowPortalRegistry.updateEntryVisibility(for: terminal.hostedView, visibleInUI: true)
            } else {
                terminal.unfocus()
                terminal.hostedView.setVisibleInUI(false)
                TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
            }
        } else if let browser = panel as? BrowserPanel {
            if !shouldBeVisible {
                browser.unfocus()
                browser.hideBrowserPortalView(source: "dockHidden")
            }
        }
    }
}
