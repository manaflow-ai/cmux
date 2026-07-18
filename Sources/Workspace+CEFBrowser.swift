import Bonsplit
import CmuxWorkspaces
import Combine
import Foundation

extension Workspace {
    /// Creates a Chromium browser tab in an existing pane.
    @discardableResult
    func newCEFBrowserSurface(
        inPane paneId: PaneID,
        url: String = "about:blank",
        profileID: UUID? = nil,
        focus: Bool? = nil
    ) -> CEFBrowserPanel? {
        guard !isRemoteTmuxMirror else { return nil }
        guard CEFRuntimeSupport.isRuntimeBundled else {
            cefBrowserLogger.error("cannot create CEF browser surface because the runtime is not bundled")
            return nil
        }

        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView
        let cefBrowserPanel = CEFBrowserPanel(
            workspaceId: id,
            profileID: profileID,
            initialURL: url
        )
        panels[cefBrowserPanel.id] = cefBrowserPanel
        panelTitles[cefBrowserPanel.id] = cefBrowserPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: cefBrowserPanel.displayTitle,
            icon: cefBrowserPanel.displayIcon,
            kind: SurfaceKind.cefBrowser.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: cefBrowserPanel.id)
            panelTitles.removeValue(forKey: cefBrowserPanel.id)
            cefBrowserPanel.close()
            return nil
        }

        bindSurface(newTabId, toPanelId: cefBrowserPanel.id)
        installCEFBrowserPanelSubscription(cefBrowserPanel)
        publishCmuxSurfaceCreated(
            cefBrowserPanel.id,
            paneId: paneId,
            kind: SurfaceKind.cefBrowser.rawValue,
            origin: "cef_browser_tab",
            focused: shouldFocusNewTab
        )

        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            cefBrowserPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: cefBrowserPanel.id,
                previousHostedView: previousHostedView
            )
        }
        return cefBrowserPanel
    }

    /// Creates a Chromium browser in a new split to the right of `panelId`.
    @discardableResult
    func newCEFBrowserSplit(
        from panelId: UUID,
        url: String = "about:blank"
    ) -> CEFBrowserPanel? {
        guard !isRemoteTmuxMirror else { return nil }
        guard CEFRuntimeSupport.isRuntimeBundled else {
            cefBrowserLogger.error("cannot create CEF browser split because the runtime is not bundled")
            return nil
        }
        guard let sourcePaneId = paneId(forPanelId: panelId) else { return nil }
        clearSplitZoom()

        let cefBrowserPanel = CEFBrowserPanel(workspaceId: id, initialURL: url)
        panels[cefBrowserPanel.id] = cefBrowserPanel
        panelTitles[cefBrowserPanel.id] = cefBrowserPanel.displayTitle

        let newTab = Bonsplit.Tab(
            title: cefBrowserPanel.displayTitle,
            icon: cefBrowserPanel.displayIcon,
            kind: SurfaceKind.cefBrowser.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false
        )
        bindSurface(newTab.id, toPanelId: cefBrowserPanel.id)
        let previousHostedView = focusedTerminalPanel?.hostedView

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(
            sourcePaneId,
            orientation: .horizontal,
            withTab: newTab,
            insertFirst: false
        ) else {
            removeSurfaceMapping(forSurfaceId: newTab.id)
            panels.removeValue(forKey: cefBrowserPanel.id)
            panelTitles.removeValue(forKey: cefBrowserPanel.id)
            cefBrowserPanel.close()
            return nil
        }

        installCEFBrowserPanelSubscription(cefBrowserPanel)
        suppressReparentFocusUntilLayoutFollowUp(
            previousHostedView,
            reason: "workspace.cefBrowserSplitReparent"
        )
        focusPanel(cefBrowserPanel.id, previousHostedView: previousHostedView)
        publishCmuxSplitCreated(
            newPaneId,
            sourcePaneId: sourcePaneId,
            orientation: .horizontal,
            surfaceId: cefBrowserPanel.id,
            kind: SurfaceKind.cefBrowser.rawValue,
            origin: "cef_browser_split",
            focused: true
        )
        return cefBrowserPanel
    }

    func installCEFBrowserPanelSubscription(_ cefBrowserPanel: CEFBrowserPanel) {
        let subscription = Publishers.CombineLatest(
            cefBrowserPanel.$title
                .removeDuplicates()
                .coalesceLatest(for: .milliseconds(100), scheduler: RunLoop.main),
            cefBrowserPanel.$isLoading.removeDuplicates()
        )
        .sink { [weak self, weak cefBrowserPanel] _, isLoading in
            guard let self,
                  let cefBrowserPanel,
                  let tabId = self.surfaceIdFromPanelId(cefBrowserPanel.id),
                  let existing = self.bonsplitController.tab(tabId) else { return }

            let nextTitle = cefBrowserPanel.displayTitle
            if self.panelTitles[cefBrowserPanel.id] != nextTitle {
                self.panelTitles[cefBrowserPanel.id] = nextTitle
            }
            let resolvedTitle = self.resolvedPanelTitle(
                panelId: cefBrowserPanel.id,
                fallback: nextTitle
            )
            let titleUpdate: String? = existing.title == resolvedTitle ? nil : resolvedTitle
            let loadingUpdate: Bool? = existing.isLoading == isLoading ? nil : isLoading
            guard titleUpdate != nil || loadingUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                hasCustomTitle: self.panelCustomTitles[cefBrowserPanel.id] != nil,
                isLoading: loadingUpdate
            )
        }
        panelSubscriptions[cefBrowserPanel.id] = subscription
    }
}
