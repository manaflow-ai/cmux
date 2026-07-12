import Bonsplit
import CmuxWorkspaces
import Combine
import Foundation

extension Workspace {
    /// Creates a Chromium browser in a new split to the right of `panelId`.
    @discardableResult
    func newCEFBrowserSplit(
        from panelId: UUID,
        url: String = "about:blank"
    ) -> CEFBrowserPanel? {
        guard !isRemoteTmuxMirror else { return nil }
        guard CEFRuntimeSupport.isRuntimeBundled else {
            NSLog("Workspace: cannot create CEF browser split because the runtime is not bundled")
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

    private func installCEFBrowserPanelSubscription(_ cefBrowserPanel: CEFBrowserPanel) {
        let subscription = Publishers.CombineLatest(
            cefBrowserPanel.$title.removeDuplicates(),
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
