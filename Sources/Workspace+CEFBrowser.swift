import AppKit
import Bonsplit
import Foundation

/// CEF-engine equivalents of ``Workspace/newBrowserSplit`` and
/// ``Workspace/newBrowserSurface``. Kept in a sibling file so the
/// 13 000-line ``Workspace.swift`` stays diff-quiet — the only change
/// over there is a one-conditional "detour to here when the feature
/// flag is on" guard.
///
/// These helpers construct a ``CEFBrowserPanel`` and share the same
/// workspace-level side effects as the WK path: Bonsplit registration,
/// lifecycle event publication, preferred-profile tracking, tab placement,
/// and focus preservation. WKWebView-only follow-up (process pool sharing,
/// rendering-state subscription, downloads, popup routing) stays on the WK
/// branch until CEF owns equivalent behavior.
///
/// v1 scope: opening a new browser pane with the CEF flag on produces
/// a CEF browser that loads its initial URL inside the cmux pane.
/// Everything else (find-in-page, devtools, profiles UI) shares cmux's
/// existing surfaces but does not yet route into the CEF engine.
extension Workspace {

    /// Create a new browser pane via `bonsplitController.splitPane`,
    /// backed by ``CEFBrowserPanel``. Returns the newly-registered
    /// panel, or nil if the split itself failed.
    @discardableResult
    func registerCEFBrowserSplit(
        fromPaneId paneId: PaneID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        url: URL?,
        preferredProfileID: UUID?,
        focus: Bool,
        creationPolicy: BrowserPanelCreationPolicy,
        initialDividerPosition: CGFloat?
    ) -> CEFBrowserPanel? {
        let sourcePanelId = effectiveSelectedPanelId(inPane: paneId)
        let panel = CEFBrowserPanel(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: sourcePanelId
            ),
            initialURL: url,
            renderInitialNavigation:
                BrowserAvailabilitySettings.isEnabled()
                || creationPolicy != .restoration,
            proxyEndpoint: remoteProxyEndpoint,
            isRemoteWorkspace: isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil
        )
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        let newTab = Bonsplit.Tab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: panel.isDirty,
            isLoading: panel.isLoading,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = panel.id
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }

        guard let newPaneId = bonsplitController.splitPane(
            paneId,
            orientation: orientation,
            withTab: newTab,
            insertFirst: insertFirst
        ) else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }
        applyInitialSplitDividerPosition(
            initialDividerPosition,
            sourcePaneId: paneId,
            newPaneId: newPaneId
        )
        setPreferredBrowserProfileID(panel.profileID)
        publishCmuxSplitCreated(
            newPaneId,
            sourcePaneId: paneId,
            orientation: orientation,
            surfaceId: panel.id,
            kind: "browser",
            origin: "browser_split",
            focused: focus
        )

        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.cefBrowserSplitReparent"
            )
            focusPanel(panel.id)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: panel.id,
                previousHostedView: previousHostedView
            )
        }
        return panel
    }

    /// Create a new browser tab inside an existing pane, backed by
    /// ``CEFBrowserPanel``.
    @discardableResult
    func registerCEFBrowserSurface(
        inPaneId paneId: PaneID,
        url: URL?,
        focus: Bool,
        selectWhenNotFocused: Bool,
        insertAtEnd: Bool,
        preferredProfileID: UUID?,
        creationPolicy: BrowserPanelCreationPolicy,
        sourcePanelId: UUID?
    ) -> CEFBrowserPanel? {
        let panel = CEFBrowserPanel(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: sourcePanelId
            ),
            initialURL: url,
            renderInitialNavigation:
                BrowserAvailabilitySettings.isEnabled()
                || creationPolicy != .restoration,
            proxyEndpoint: remoteProxyEndpoint,
            isRemoteWorkspace: isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil
        )
        panels[panel.id] = panel
        panelTitles[panel.id] = panel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: panel.displayTitle,
            icon: panel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: panel.isDirty,
            isLoading: panel.isLoading,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: panel.id)
            panelTitles.removeValue(forKey: panel.id)
            return nil
        }
        surfaceIdToPanelId[newTabId] = panel.id
        setPreferredBrowserProfileID(panel.profileID)
        if insertAtEnd {
            let targetIndex = max(0, bonsplitController.tabs(inPane: paneId).count - 1)
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            panel.id,
            paneId: paneId,
            kind: "browser",
            origin: "browser_tab",
            focused: focus
        )

        if focus {
            let previousHostedView = focusedTerminalPanel?.hostedView
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            panel.focus()
            applyTabSelection(
                tabId: newTabId,
                inPane: paneId,
                previousTerminalHostedView: previousHostedView
            )
        } else {
            if selectWhenNotFocused {
                hideBrowserPortalsForDeselectedTabs(inPane: paneId, selectedTabId: newTabId)
            }
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: focusedPanelId,
                splitPanelId: panel.id,
                previousHostedView: focusedTerminalPanel?.hostedView
            )
        }
        return panel
    }
}
