import AppKit
import WebKit

@available(macOS 15.4, *)
extension BrowserWebExtensionSupport: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        let openWindows: [any WKWebExtensionWindow] = [windowAdapter] + popouts(for: extensionContext)
        guard let focusedWindow = focusedWebExtensionWindow(for: NSApp.keyWindow, among: openWindows) else {
            return openWindows
        }
        let focusedID = ObjectIdentifier(focusedWindow as AnyObject)
        return [focusedWindow] + openWindows.filter {
            ObjectIdentifier($0 as AnyObject) != focusedID
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        let openWindows: [any WKWebExtensionWindow] = [windowAdapter] + popouts(for: extensionContext)
        return focusedWebExtensionWindow(for: NSApp.keyWindow, among: openWindows)
    }

    private func popouts(for extensionContext: WKWebExtensionContext) -> [BrowserWebExtensionPopoutWindowController] {
        popouts.filter { $0.extensionContext === extensionContext }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void
    ) {
#if DEBUG
        cmuxDebugLog(
            "browser.webext.openWindow type=\(configuration.windowType.rawValue) " +
            "urls=\(configuration.tabURLs.count) focused=\(configuration.shouldBeFocused ? 1 : 0)"
        )
#endif
        guard !configuration.shouldBePrivate else {
            completionHandler(nil, openTabsUnsupportedError())
            return
        }
        guard configuration.windowType == .popup else {
            guard configuration.windowType == .normal,
                  let window = openNormalBrowserWindow(using: configuration, for: extensionContext) else {
                completionHandler(nil, openTabsUnsupportedError())
                return
            }
            completionHandler(window, nil)
            return
        }
        guard configuration.tabURLs.allSatisfy({ canOpenExtensionPopupURL($0, for: extensionContext) }) else {
            completionHandler(nil, openTabsUnsupportedError())
            return
        }
        let popout = BrowserWebExtensionPopoutWindowController(
            configuration: configuration,
            context: extensionContext,
            support: self
        )
        popouts.append(popout)
        controller.didOpenWindow(popout)
        controller.didOpenTab(popout.tab)
        if popout.isKeyWindow {
            controller.didFocusWindow(popout)
        }
        completionHandler(popout, nil)
    }

    private func openNormalBrowserWindow(
        using configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        guard !configuration.tabURLs.isEmpty else {
            guard configuration.tabs.isEmpty else {
                return windowAdapter
            }
            return openBrowserTab(
                url: nil,
                shouldActivate: configuration.shouldBeFocused,
                webViewConfiguration: nil
            ).map { _ in windowAdapter }
        }

        let requestedTabs = configuration.tabURLs.map { url in
            (url: url, webViewConfiguration: webViewConfigurationForExtensionRequestedBrowserURL(url, for: extensionContext))
        }
        guard requestedTabs.allSatisfy({ canOpenExtensionRequestedBrowserURL($0.url, for: extensionContext) }) else {
            return nil
        }

        var openedPanels: [BrowserPanel] = []
        for (index, requestedTab) in requestedTabs.enumerated() {
            let shouldActivate = configuration.shouldBeFocused && index == 0
            guard let adapter = openBrowserTab(
                url: requestedTab.url,
                shouldActivate: shouldActivate,
                webViewConfiguration: requestedTab.webViewConfiguration
            ), let panel = adapter.panel else {
                openedPanels.reversed().forEach(closeOpenedBrowserTab)
                return nil
            }
            openedPanels.append(panel)
        }
        return windowAdapter
    }

    func closeOpenedBrowserTab(_ panel: BrowserPanel) {
        if let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panel.id,
            preferredWorkspaceId: panel.workspaceId
        )?.workspace {
            _ = workspace.closePanel(panel.id, force: true)
            return
        }
        guard let dock = dockContainingPanel(panel.id),
              let tabId = dock.surfaceId(forPanelId: panel.id) else { return }
        dock.forceCloseDockTabIds.insert(tabId)
        if !dock.bonsplitController.closeTab(tabId) {
            dock.forceCloseDockTabIds.remove(tabId)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void
    ) {
#if DEBUG
        cmuxDebugLog("browser.webext.openTab url=\(configuration.url?.absoluteString.prefix(80) ?? "nil")")
#endif
        if let url = configuration.url,
           !canOpenExtensionRequestedBrowserURL(url, for: extensionContext) {
            completionHandler(nil, openTabsUnsupportedError())
            return
        }

        guard let adapter = openBrowserTab(
            url: configuration.url,
            shouldActivate: configuration.shouldBeActive,
            webViewConfiguration: configuration.url.flatMap { webViewConfigurationForExtensionRequestedBrowserURL($0, for: extensionContext) }
        ) else {
            completionHandler(nil, openTabsUnsupportedError())
            return
        }
        completionHandler(adapter, nil)
    }

    func openBrowserTab(
        url: URL?,
        shouldActivate: Bool,
        webViewConfiguration: WKWebViewConfiguration?
    ) -> BrowserWebExtensionTabAdapter? {
        if let sourcePanel = activeTabAdapter?.panel {
            if let panel = openWorkspaceBrowserTab(
                sourcePanel: sourcePanel,
                url: url,
                shouldActivate: shouldActivate,
                webViewConfiguration: webViewConfiguration
            ) {
                return tabAdapterForOpenedPanel(panel, shouldActivate: shouldActivate)
            }
            if let panel = openDockBrowserTab(
                sourcePanel: sourcePanel,
                url: url,
                shouldActivate: shouldActivate,
                webViewConfiguration: webViewConfiguration
            ) {
                return tabAdapterForOpenedPanel(panel, shouldActivate: shouldActivate)
            }
        }

        guard let tabManager = AppDelegate.shared?.activeTabManagerForCommands(
            preferredWindow: NSApp.keyWindow ?? NSApp.mainWindow
        ) else { return nil }
        return openBrowserTab(
            in: tabManager,
            url: url,
            shouldActivate: shouldActivate,
            webViewConfiguration: webViewConfiguration
        )
    }

    func openBrowserTab(
        in tabManager: TabManager,
        url: URL?,
        shouldActivate: Bool,
        webViewConfiguration: WKWebViewConfiguration?
    ) -> BrowserWebExtensionTabAdapter? {
        guard let workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first,
              let paneID = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else { return nil }
        if tabManager.selectedTabId != workspace.id {
            tabManager.selectWorkspace(workspace)
        }
        guard let panel = workspace.newBrowserSurface(
            inPane: paneID,
            url: url,
            focus: shouldActivate,
            preferredProfileID: workspace.preferredBrowserProfileID,
            webViewConfiguration: webViewConfiguration
        ) else { return nil }
        return tabAdapterForOpenedPanel(panel, shouldActivate: shouldActivate)
    }

    private func openWorkspaceBrowserTab(
        sourcePanel: BrowserPanel,
        url: URL?,
        shouldActivate: Bool,
        webViewConfiguration: WKWebViewConfiguration?
    ) -> BrowserPanel? {
        guard let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: sourcePanel.id,
            preferredWorkspaceId: sourcePanel.workspaceId
        )?.workspace,
            let paneId = workspace.paneId(forPanelId: sourcePanel.id) else {
            return nil
        }
        return workspace.newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: shouldActivate,
            preferredProfileID: sourcePanel.profileID,
            webViewConfiguration: webViewConfiguration
        )
    }

    private func openDockBrowserTab(
        sourcePanel: BrowserPanel,
        url: URL?,
        shouldActivate: Bool,
        webViewConfiguration: WKWebViewConfiguration?
    ) -> BrowserPanel? {
        guard let dock = dockContainingPanel(sourcePanel.id),
              let paneId = dock.paneId(forPanelId: sourcePanel.id),
              let panelID = dock.newSurface(
                  kind: .browser,
                  inPane: paneId,
                  url: url,
                  focus: shouldActivate,
                  preferredProfileID: sourcePanel.profileID,
                  webViewConfiguration: webViewConfiguration
              ) else { return nil }
        return dock.browserPanel(for: panelID)
    }

    private func tabAdapterForOpenedPanel(
        _ panel: BrowserPanel,
        shouldActivate: Bool
    ) -> BrowserWebExtensionTabAdapter? {
        if shouldActivate {
            noteActivated(panelID: panel.id)
        }
        return tabAdapter(for: panel.id)
    }

    func focusOwningCmuxTab(panelID: UUID, workspaceId: UUID) -> Bool {
        if let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelID,
            preferredWorkspaceId: workspaceId
        )?.workspace {
            workspace.focusPanel(panelID)
            return true
        }
        guard let dock = dockContainingPanel(panelID) else { return false }
        dock.focusPanel(panelID)
        return true
    }

    func closeBrowserTab(panelID: UUID, workspaceID: UUID) -> Bool {
        if let workspace = AppDelegate.shared?.workspaceContainingPanel(
            panelId: panelID,
            preferredWorkspaceId: workspaceID
        )?.workspace {
            workspace.markCloseHistoryEligible(panelId: panelID)
            return workspace.closePanel(panelID, force: true)
        }
        guard let dock = dockContainingPanel(panelID) else { return false }
        return dock.closePanel(panelID, force: true)
    }

    private func dockContainingPanel(_ panelID: UUID) -> DockSplitStore? {
        DockSplitStore.liveStores.first { $0.containsPanel(panelID) }
    }

    func canOpenExtensionRequestedBrowserURL(_ url: URL, for extensionContext: WKWebExtensionContext) -> Bool {
        canOpenInRegularBrowserTab(url) || controller.extensionContext(for: url) === extensionContext
    }

    func canOpenExtensionPopupURL(_ url: URL, for extensionContext: WKWebExtensionContext) -> Bool {
        // Standalone popout WKWebViews bypass BrowserPanel navigation policy, so
        // only extension-owned pages may load here.
        controller.extensionContext(for: url) === extensionContext
    }

    func webViewConfigurationForExtensionRequestedBrowserURL(_ url: URL, for extensionContext: WKWebExtensionContext) -> WKWebViewConfiguration? {
        guard controller.extensionContext(for: url) === extensionContext else { return nil }
        return extensionContext.webViewConfiguration
    }

    private func canOpenInRegularBrowserTab(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return scheme == "http" || scheme == "https" || scheme == "about"
    }

    private func openTabsUnsupportedError() -> NSError {
        NSError(
            domain: "cmux.webExtension",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: String(
                localized: "browser.webExtension.error.openTabsUnsupported",
                defaultValue: "Opening extension tabs is not supported yet."
            )]
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        refreshActionSnapshot(for: action, context: context)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let popover = action.popupPopover else {
            completionHandler(nil)
            return
        }
        let candidates: [NSView?] = [
            pendingPopupAnchorView,
            activeTabAdapter?.panel?.webView,
            orderedTabAdapters.first(where: { $0.panel?.webView.window != nil })?.panel?.webView,
            NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView,
        ]
        pendingPopupAnchorView = nil
        guard let anchor = candidates.compactMap({ $0 }).first(where: { $0.window != nil }) else {
#if DEBUG
            cmuxDebugLog("browser.webext.actionPopup no window-attached anchor; dropping popup")
#endif
            completionHandler(nil)
            return
        }
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let requested = permissions
            .map { String(describing: $0) }
            .sorted()
            .joined(separator: "\n")
        let allowed = confirmPermissionRequest(
            informativeText: permissionMessage(
                extensionContext: extensionContext,
                details: requested,
                key: "browser.webExtension.permissionPrompt.permissions.message",
                defaultValue: "The extension “%@” wants these browser permissions:\n\n%@"
            )
        )
        completionHandler(allowed ? permissions : [], nil)
        persistPermissionStateSoon(for: extensionContext)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let requested = urls
            .map(\.absoluteString)
            .sorted()
            .joined(separator: "\n")
        let allowed = confirmPermissionRequest(
            informativeText: permissionMessage(
                extensionContext: extensionContext,
                details: requested,
                key: "browser.webExtension.permissionPrompt.urls.message",
                defaultValue: "The extension “%@” wants access to these pages:\n\n%@"
            )
        )
        completionHandler(allowed ? urls : [], nil)
        persistPermissionStateSoon(for: extensionContext)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let requested = matchPatterns
            .map { String(describing: $0) }
            .sorted()
            .joined(separator: "\n")
        let allowed = confirmPermissionRequest(
            informativeText: permissionMessage(
                extensionContext: extensionContext,
                details: requested,
                key: "browser.webExtension.permissionPrompt.matchPatterns.message",
                defaultValue: "The extension “%@” wants access to matching pages:\n\n%@"
            )
        )
        completionHandler(allowed ? matchPatterns : [], nil)
        persistPermissionStateSoon(for: extensionContext)
    }

    private func permissionMessage(
        extensionContext: WKWebExtensionContext,
        details: String,
        key: StaticString,
        defaultValue: String.LocalizationValue
    ) -> String {
        let extensionName = extensionContext.webExtension.displayName ?? String(
            localized: "browser.webExtension.action.help",
            defaultValue: "Extension"
        )
        return String.localizedStringWithFormat(
            String(localized: key, defaultValue: defaultValue),
            extensionName,
            details
        )
    }

    private func confirmPermissionRequest(informativeText: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "browser.webExtension.permissionPrompt.title",
            defaultValue: "Allow Extension Access?"
        )
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(
            localized: "browser.webExtension.permissionPrompt.allow",
            defaultValue: "Allow"
        ))
        alert.addButton(withTitle: String(
            localized: "browser.webExtension.permissionPrompt.deny",
            defaultValue: "Deny"
        ))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
