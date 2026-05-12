import AppKit
import Bonsplit
import Foundation

/// CEF-engine equivalents of ``Workspace/newBrowserSplit`` and
/// ``Workspace/newBrowserSurface``. Kept in a sibling file so the
/// 13 000-line ``Workspace.swift`` stays diff-quiet — the only change
/// over there is a one-conditional "detour to here when the feature
/// flag is on" guard.
///
/// These helpers are intentionally minimal: they construct a
/// ``CEFBrowserPanel``, register it in the workspace's panel map, and
/// hand a Bonsplit tab to ``BonsplitController``. They do *not*
/// replicate the WKWebView-specific follow-up (process pool sharing,
/// rendering-state subscription, remote-workspace status, downloads,
/// popup routing). Those are wired in follow-up PRs per
/// `Prototypes/cef-webview/notes/cmux-integration-plan.md` §Step 3+.
///
/// v1 scope: opening a new browser pane with the CEF flag on produces
/// a CEF browser that loads its initial URL inside the cmux pane.
/// Everything else (find-in-page, devtools, profiles UI) shares cmux's
/// existing surfaces but does not yet route into the CEF engine.
extension Workspace {

    /// Create a new browser pane via `bonsplitController.splitPane`,
    /// backed by ``CEFBrowserPanel``. Returns the newly-registered
    /// panel id, or nil if the split itself failed.
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
    ) -> UUID? {
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

        if focus {
            focusPanel(panel.id)
        }
        return panel.id
    }

    /// Create a new browser tab inside an existing pane, backed by
    /// ``CEFBrowserPanel``.
    @discardableResult
    func registerCEFBrowserSurface(
        inPaneId paneId: PaneID,
        url: URL?,
        focus: Bool,
        preferredProfileID: UUID?,
        creationPolicy: BrowserPanelCreationPolicy,
        sourcePanelId: UUID?
    ) -> UUID? {
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

        if focus {
            bonsplitController.selectTab(newTabId)
            focusPanel(panel.id)
        }
        return panel.id
    }
}
