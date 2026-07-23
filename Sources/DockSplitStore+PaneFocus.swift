import AppKit
import Bonsplit

extension DockSplitStore {
    var focusedPanelId: UUID? {
        guard let paneId = bonsplitController.focusedPaneId,
              let tabId = bonsplitController.selectedTab(inPane: paneId)?.id else { return nil }
        return surfaceIdToPanelId[tabId]
    }

    /// Whether a panel id is present in the Dock tree.
    func containsPanel(_ panelId: UUID) -> Bool {
        panels[panelId] != nil
    }

    func containsPane(_ paneId: UUID) -> Bool {
        bonsplitController.allPaneIds.contains(where: { $0.id == paneId })
    }

    /// Resolves a Dock pane for `surface.create --placement dock`. An explicit
    /// `requestedPaneID` must match a Dock pane; otherwise the focused/first pane
    /// is used after ensuring the Dock has loaded its root pane.
    func resolvePane(requestedPaneID: UUID?) -> PaneID? {
        ensureLoaded()
        if let requestedPaneID {
            return bonsplitController.allPaneIds.first(where: { $0.id == requestedPaneID })
        }
        return bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first
    }

    func resolveSourcePanelId(_ requested: UUID?, preferredPaneId: PaneID? = nil) -> UUID? {
        if let requested, panels[requested] != nil { return requested }
        if let preferredPaneId,
           let tabId = bonsplitController.selectedTab(inPane: preferredPaneId)?.id,
           let panelId = surfaceIdToPanelId[tabId] {
            return panelId
        }
        if let focused = focusedPanelId { return focused }
        return panels.keys.first
    }

    func focusPanel(_ panelId: UUID) {
        guard let paneId = paneId(forPanelId: panelId), let tabId = surfaceId(forPanelId: panelId) else { return }
        bonsplitController.focusPane(paneId)
        bonsplitController.selectTab(tabId)
        applyDockSelection(tabId: tabId, inPane: paneId)
    }

    func triggerFocusFlash(panelId: UUID) {
        panels[panelId]?.triggerFlash(reason: .navigation)
    }

    func focusFirstControl() -> Bool {
        guard let paneId = bonsplitController.allPaneIds.first else { return false }
        bonsplitController.focusPane(paneId)
        guard let tabId = bonsplitController.selectedTab(inPane: paneId)?.id,
              let panelId = surfaceIdToPanelId[tabId],
              let panel = panels[panelId] else { return false }
        panel.focus()
        return true
    }

    func noteKeyboardFocusIntent(window: NSWindow?) {
        guard let appDelegate = AppDelegate.shared else { return }
        // Bind the note to this store's owning window context first: per-window
        // docks satisfy `workspaceId == windowId` (`AppDelegate+WindowDock.swift`),
        // and the Dock UI renders inside its owner, so the owner is the window
        // the user interacted with regardless of transient key/main-window state
        // (during a cross-window drag the SOURCE window can still be key; see
        // the matching owner resolution in `AppDelegate+DockSurfaceMove.swift`).
        // Workspace-scoped docks have no owning window; for them honor the
        // caller-resolved window, as the pre-#7522 note did. Never fall back to
        // ambient key/main/first-context state: noting a context that does not
        // own the interaction would route the next creation shortcut into a
        // Dock the user never touched. No owner and no window drops the note.
        let coordinator = appDelegate.mainWindowContexts.values
            .first(where: { $0.windowId == workspaceId })?
            .keyboardFocusCoordinator
            ?? appDelegate.keyboardFocusCoordinator(for: window)
        coordinator?.noteRightSidebarInteraction(mode: .dock)
    }

    /// Creates a Dock surface from a clicked Dock affordance.
    ///
    /// A click on an empty-pane button is explicit Dock interaction, matching the
    /// Dock intent note from `GhosttyTerminalView.mouseDown` for issue #7522.
    /// Plain `newSurface` stays intent-neutral for socket-created Dock surfaces.
    @discardableResult
    func newSurfaceFromDockAffordance(kind: DockSurfaceKind, inPane paneId: PaneID, window: NSWindow?) -> UUID? {
        noteKeyboardFocusIntent(window: window)
        return newSurface(kind: kind, inPane: paneId, focus: true)
    }

    /// Focuses a Dock pane from a clicked Dock affordance.
    ///
    /// A pane-background click is explicit Dock interaction, matching the Dock
    /// intent note from `GhosttyTerminalView.mouseDown` for issue #7522.
    func focusPaneFromDockClick(_ paneId: PaneID, window: NSWindow?) {
        noteKeyboardFocusIntent(window: window)
        bonsplitController.focusPane(paneId)
    }

    func browserPanel(owning responder: NSResponder?, in window: NSWindow?) -> BrowserPanel? {
        guard let responder, let window else { return nil }
        if let focused = focusedPanelId,
           let browser = panels[focused] as? BrowserPanel,
           browser.ownedFocusIntent(for: responder, in: window) != nil {
            return browser
        }
        for (panelId, panel) in panels {
            guard panelId != focusedPanelId,
                  let browser = panel as? BrowserPanel,
                  browser.ownedFocusIntent(for: responder, in: window) != nil else {
                continue
            }
            return browser
        }
        return nil
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

    func paneIsRenderedInVisibleDock(_ paneId: PaneID) -> Bool {
        guard isVisibleInUI else { return false }
        guard let zoomedPaneId = bonsplitController.zoomedPaneId else { return true }
        return zoomedPaneId == paneId
    }

    func panelIsSelectedInVisibleDockPane(_ panelId: UUID) -> Bool {
        guard let tabId = surfaceId(forPanelId: panelId),
              let paneId = paneId(forPanelId: panelId) else { return false }
        guard paneIsRenderedInVisibleDock(paneId) else { return false }
        return bonsplitController.selectedTab(inPane: paneId)?.id == tabId
    }

    func panelIsActiveInVisibleDockPane(_ panelId: UUID) -> Bool {
        panelIsSelectedInVisibleDockPane(panelId) && focusedPanelId == panelId
    }

    @discardableResult
    func toggleDockPaneZoom(inPane paneId: PaneID) -> Bool {
        guard bonsplitController.togglePaneZoom(inPane: paneId) else { return false }
        bonsplitController.focusPane(paneId)
        applyVisibilityToAllPanels()
        scheduleDockPortalReconcile(reason: "dock.zoom")
        return true
    }

    func applyVisibilityToAllPanels() {
        forEachPanel { _, panel in applyVisibility(to: panel) }
    }

    func withCoalescedTerminalViewReattach(_ body: () -> Void) {
        terminalViewReattachCoalescingDepth += 1
        defer {
            terminalViewReattachCoalescingDepth -= 1
            if terminalViewReattachCoalescingDepth == 0 {
                let pendingPanelIds = pendingTerminalViewReattachPanelIds
                pendingTerminalViewReattachPanelIds.removeAll()
                for panelId in pendingPanelIds {
                    (panels[panelId] as? TerminalPanel)?.requestViewReattach()
                }
            }
        }
        body()
    }

    func requestTerminalViewReattach(_ terminal: TerminalPanel) {
        if terminalViewReattachCoalescingDepth > 0 {
            pendingTerminalViewReattachPanelIds.insert(terminal.id)
        } else {
            terminal.requestViewReattach()
        }
    }

    func applyFocusedDockSelection() {
        guard let paneId = bonsplitController.focusedPaneId,
              let tabId = bonsplitController.selectedTab(inPane: paneId)?.id else {
            applyVisibilityToAllPanels()
            scheduleDockPortalReconcile(reason: "dock.selection.empty")
            return
        }
        applyDockSelection(tabId: tabId, inPane: paneId)
        scheduleDockPortalReconcile(reason: "dock.selection.focused")
    }

    func applyDockSelection(tabId: TabID, inPane pane: PaneID) {
        applyVisibilityToAllPanels()
        guard paneIsRenderedInVisibleDock(pane),
              bonsplitController.focusedPaneId == pane,
              let selectedPanel = panel(for: tabId) else { return }

        focusHistoryNavigation.recordFocusInHistory(
            workspaceId: workspaceId,
            panelId: selectedPanel.id,
            preservingForwardBranch: false
        )
        let activationIntent = selectedPanel.preferredFocusIntentForActivation()
        selectedPanel.prepareFocusIntentForActivation(activationIntent)
        forEachPanel { panelId, panel in
            if panelId != selectedPanel.id {
                panel.unfocus()
            }
        }
        selectedPanel.focus()
    }

    func splitTabBarDividerDragDidBegin(_ controller: BonsplitController) {
        TerminalWindowPortalRegistry.beginInteractiveGeometryResize(
            owner: controller,
            in: terminalResizeInteractionWindow()
        )
    }

    func splitTabBarDividerDragDidEnd(_ controller: BonsplitController) {
        TerminalWindowPortalRegistry.endInteractiveGeometryResize(owner: controller)
    }

    private func terminalResizeInteractionWindow() -> NSWindow? {
        if let eventWindow = NSApp.currentEvent?.window { return eventWindow }
        return panels.values.lazy.compactMap { panel in
            (panel as? TerminalPanel)?.hostedView.window
        }.first
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

    /// Mirrors `Workspace.splitTabBar(_:didSplitPane:…)` so the Dock's split
    /// buttons (Split Right / Split Down) and drag-to-split behave like the main
    /// split area. `splitPane` always creates an EMPTY new pane; without this the
    /// Dock's `autoCloseEmptyPanes` config tears it down immediately, so a split
    /// appeared to do nothing.
    func splitTabBar(
        _ controller: BonsplitController,
        didSplitPane originalPane: PaneID,
        newPane: PaneID,
        orientation: SplitOrientation
    ) {
        scheduleDockPortalReconcile(reason: "dock.splitPane")
        // Programmatic splits (config seed, `newSplit`, cross-container transfer)
        // seed their own new-pane tab, so don't auto-create another.
        guard !isProgrammaticDockSplit else { return }

        if !controller.tabs(inPane: newPane).isEmpty {
            // Drag-to-split: an existing tab was dragged to a pane edge. Bonsplit
            // may leave the source pane holding only a placeholder "Empty" tab —
            // replace it with a real terminal so we never show a tabless pane.
            repairPlaceholderOnlyDockPane(originalPane)
            return
        }

        // Split button: the new pane is empty. Seed a terminal in it, matching
        // the main area (which always seeds a terminal on a UI split).
        let sourcePanelId = (controller.selectedTab(inPane: originalPane)?.id)
            .flatMap { surfaceIdToPanelId[$0] }
        _ = newSurface(
            kind: .terminal,
            inPane: newPane,
            sourcePanelId: sourcePanelId,
            focus: true
        )
    }

    /// Mirrors `Workspace.splitTabBar(_:didMoveTab:…)`: keep the moved panel
    /// selected/focused in its destination pane and re-render it at the new
    /// geometry when a tab is dragged between Dock panes.
    func splitTabBar(
        _ controller: BonsplitController,
        didMoveTab tab: Bonsplit.Tab,
        fromPane source: PaneID,
        toPane destination: PaneID
    ) {
        applyDockSelection(tabId: tab.id, inPane: destination)
        let movedPanel = panel(for: tab.id)
        (movedPanel as? TerminalPanel)?.recordPortalHostOwnershipChange()
        movedPanel?.focus()
        scheduleDockPortalReconcile(reason: "dock.moveTab")
    }

    /// Replaces an empty or placeholder-only pane with a real Dock terminal,
    /// dropping any placeholder tabs left behind by the split operation.
    func repairPlaceholderOnlyDockPane(_ pane: PaneID) {
        let tabs = bonsplitController.tabs(inPane: pane)
        guard !tabs.contains(where: { panel(for: $0.id) != nil }) else { return }
        _ = newSurface(kind: .terminal, inPane: pane, focus: false)
        for tab in bonsplitController.tabs(inPane: pane) where panel(for: tab.id) == nil {
            _ = bonsplitController.closeTab(tab.id)
        }
    }

    func applyVisibility(to panel: any Panel) {
        let shouldBeVisible = panelIsSelectedInVisibleDockPane(panel.id)
        let shouldBeActive = panelIsActiveInVisibleDockPane(panel.id)
        if let terminal = panel as? TerminalPanel {
            if shouldBeVisible {
                terminal.hostedView.setVisibleInUI(true)
                terminal.hostedView.setActive(shouldBeActive)
                let needsPortalReattach = TerminalWindowPortalRegistry
                    .updateEntryVisibility(for: terminal.hostedView, visibleInUI: true)
                if needsPortalReattach {
                    requestTerminalViewReattach(terminal)
                }
            } else {
                terminal.unfocus()
                terminal.hostedView.setVisibleInUI(false)
                TerminalWindowPortalRegistry.hideHostedView(terminal.hostedView)
            }
        } else if let browser = panel as? BrowserPanel {
            if shouldBeVisible {
                browser.noteWebViewVisibility(
                    true,
                    reason: "portal.dockVisible",
                    recordIfUnchanged: true
                )
                BrowserWindowPortalRegistry.updateEntryVisibility(
                    for: browser.webView,
                    visibleInUI: true,
                    zPriority: 1
                )
                if dockBrowserPortalNeedsReconcile(browser) {
                    scheduleDockPortalReconcile(reason: "dock.browserVisible")
                }
            } else {
                browser.unfocus()
                browser.hideBrowserPortalView(source: "dockHidden")
            }
        }
    }
}
