import Foundation
import SwiftUI
import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxSocketControl
import Combine
import CryptoKit
import Darwin
import Network
import CoreText


// MARK: - Browser surface creation
extension Workspace {
    /// Create a new browser panel split
    @discardableResult
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil,
        preferredProfileID: UUID? = nil,
        focus: Bool = true,
        creationPolicy: BrowserPanelCreationPolicy = .userInitiated,
        omnibarVisible: Bool = true,
        transparentBackground: Bool = false,
        bypassRemoteProxy: Bool = false,
        initialDividerPosition: CGFloat? = nil
    ) -> BrowserPanel? {
        let browserEnabled = BrowserAvailabilitySettings.isEnabled()
        guard browserEnabled || creationPolicy.permitsCreationWhenBrowserDisabled else {
            if let url {
                _ = NSWorkspace.shared.open(url)
            }
            return nil
        }

        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        // Create browser panel
        let browserPanel = BrowserPanel(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: panelId
            ),
            initialURL: url,
            renderInitialNavigation: browserEnabled || creationPolicy != .restoration,
            preloadInitialNavigationInBackground: creationPolicy.preloadsInitialNavigationInBackground,
            omnibarVisible: omnibarVisible,
            transparentBackground: transparentBackground,
            proxyEndpoint: remoteProxyEndpoint,
            bypassRemoteProxy: bypassRemoteProxy,
            isRemoteWorkspace: isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil
        )
        configureBrowserPanel(browserPanel)
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        // Pre-generate the bonsplit tab ID so the mapping exists before the split lands.
        let newTab = Bonsplit.Tab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isAudioMuted: browserPanel.isMuted,
            isPinned: false
        )
        surfaceIdToPanelId[newTab.id] = browserPanel.id
        let previousFocusedPanelId = focusedPanelId

        // Create the split with the browser tab already present.
        // Mark this split as programmatic so didSplitPane doesn't auto-create a terminal.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) else {
            surfaceIdToPanelId.removeValue(forKey: newTab.id)
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }
        applyInitialSplitDividerPosition(initialDividerPosition, sourcePaneId: paneId, newPaneId: newPaneId)
        setPreferredBrowserProfileID(browserPanel.profileID)
        publishCmuxSplitCreated(newPaneId, sourcePaneId: paneId, orientation: orientation, surfaceId: browserPanel.id, kind: "browser", origin: "browser_split", focused: focus)

        // See newTerminalSplit: suppress old view's becomeFirstResponder during reparenting.
        let previousHostedView = focusedTerminalPanel?.hostedView
        if focus {
            suppressReparentFocusUntilLayoutFollowUp(
                previousHostedView,
                reason: "workspace.browserSplitReparent"
            )
            focusPanel(browserPanel.id)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: browserPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installBrowserPanelSubscription(browserPanel)
        browserPanel.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())

        return browserPanel
    }

    /// Create a new browser surface in the specified pane.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL? = nil,
        initialRequest: URLRequest? = nil,
        focus: Bool? = nil,
        selectWhenNotFocused: Bool = false,
        insertAtEnd: Bool = false,
        preferredProfileID: UUID? = nil,
        bypassInsecureHTTPHostOnce: String? = nil,
        creationPolicy: BrowserPanelCreationPolicy = .userInitiated,
        omnibarVisible: Bool = true,
        transparentBackground: Bool = false,
        bypassRemoteProxy: Bool = false
    ) -> BrowserPanel? {
        let browserEnabled = BrowserAvailabilitySettings.isEnabled()
        guard browserEnabled || creationPolicy.permitsCreationWhenBrowserDisabled else {
            if let externalURL = url ?? initialRequest?.url {
                _ = NSWorkspace.shared.open(externalURL)
            }
            return nil
        }

        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let sourcePanelId = effectiveSelectedPanelId(inPane: paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalPanel?.hostedView

        let browserPanel = BrowserPanel(
            workspaceId: id,
            profileID: resolvedNewBrowserProfileID(
                preferredProfileID: preferredProfileID,
                sourcePanelId: sourcePanelId
            ),
            initialURL: url,
            initialRequest: initialRequest,
            renderInitialNavigation: browserEnabled || creationPolicy != .restoration,
            preloadInitialNavigationInBackground: creationPolicy.preloadsInitialNavigationInBackground,
            bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce,
            omnibarVisible: omnibarVisible,
            transparentBackground: transparentBackground,
            proxyEndpoint: remoteProxyEndpoint,
            bypassRemoteProxy: bypassRemoteProxy,
            isRemoteWorkspace: isRemoteWorkspace,
            remoteWebsiteDataStoreIdentifier: isRemoteWorkspace ? id : nil
        )
        configureBrowserPanel(browserPanel)
        panels[browserPanel.id] = browserPanel
        panelTitles[browserPanel.id] = browserPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            kind: SurfaceKind.browser,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            isAudioMuted: browserPanel.isMuted,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: browserPanel.id)
            panelTitles.removeValue(forKey: browserPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = browserPanel.id
        setPreferredBrowserProfileID(browserPanel.profileID)

        // Keyboard/browser-open paths want "new tab at end" regardless of global new-tab placement.
        if insertAtEnd {
            let targetIndex = max(0, bonsplitController.tabs(inPane: paneId).count - 1)
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(browserPanel.id, paneId: paneId, kind: "browser", origin: "browser_tab", focused: shouldFocusNewTab)

        // Match terminal behavior: enforce deterministic selection + focus.
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            browserPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            if selectWhenNotFocused {
                hideBrowserPortalsForDeselectedTabs(inPane: paneId, selectedTabId: newTabId)
            }
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: browserPanel.id,
                previousHostedView: previousHostedView
            )
        }

        installBrowserPanelSubscription(browserPanel)
        browserPanel.setRemoteWorkspaceStatus(browserRemoteWorkspaceStatusSnapshot())

        return browserPanel
    }

    /// Creates a sidebar extension browser tab in the requested pane and returns its panel.
    ///
    /// - Parameters:
    ///   - paneId: The pane that should receive the extension browser tab.
    ///   - title: The display title used for the tab and panel.
    ///   - focus: When true, selects the new tab and moves focus to its pane. The tab is not restored from saved workspace sessions.
    /// - Returns: The created extension browser panel, or `nil` if the pane cannot accept a new tab.
    @discardableResult
    func newSidebarExtensionBrowserSurface(
        inPane paneId: PaneID,
        title: String,
        focus: Bool = true
    ) -> CMUXSidebarExtensionBrowserPanel? {
        let shouldFocusNewTab = focus || bonsplitController.focusedPaneId == paneId
        let extensionBrowserPanel = CMUXSidebarExtensionBrowserPanel(title: title)
        panels[extensionBrowserPanel.id] = extensionBrowserPanel
        panelTitles[extensionBrowserPanel.id] = extensionBrowserPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: extensionBrowserPanel.displayTitle,
            icon: extensionBrowserPanel.displayIcon,
            kind: SurfaceKind.extensionBrowser,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: extensionBrowserPanel.id)
            panelTitles.removeValue(forKey: extensionBrowserPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = extensionBrowserPanel.id
        publishCmuxSurfaceCreated(
            extensionBrowserPanel.id,
            paneId: paneId,
            kind: SurfaceKind.extensionBrowser,
            origin: "extension_browser_tab",
            focused: shouldFocusNewTab
        )

        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            extensionBrowserPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }

        return extensionBrowserPanel
    }

}
