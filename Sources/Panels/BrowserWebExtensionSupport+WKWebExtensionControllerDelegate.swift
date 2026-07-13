import AppKit
import WebKit

@available(macOS 15.4, *)
extension BrowserWebExtensionSupport: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        let openWindows: [any WKWebExtensionWindow] = normalWindowAdaptersInFocusOrder + popouts(for: extensionContext)
        guard let focusedWindow = webExtensionController(controller, focusedWindowFor: extensionContext) else {
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
        guard let focusedWindow = focusedWebExtensionWindow(for: NSApp.keyWindow) else {
            return nil
        }
        if let popout = focusedWindow as? BrowserWebExtensionPopoutWindowController {
            return popout.extensionContext === extensionContext ? popout : nil
        }
        return focusedWindow
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
        extensionContext.didOpenWindow(popout)
        extensionContext.didOpenTab(popout.tab)
        if popout.isKeyWindow {
            extensionContext.didFocusWindow(popout)
        }
        completionHandler(popout, nil)
    }
    private func openNormalBrowserWindow(
        using configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        // Moving existing tabs into a newly created native window is not yet
        // supported. Reject that shape instead of returning the tab's old window.
        guard configuration.tabs.isEmpty else { return nil }
        let requestedTabs: [(url: URL?, webViewConfiguration: WKWebViewConfiguration?)]
        if configuration.tabURLs.isEmpty {
            requestedTabs = [(nil, nil)]
        } else {
            guard configuration.tabURLs.allSatisfy({
                canOpenExtensionRequestedBrowserURL($0, for: extensionContext)
            }) else { return nil }
            requestedTabs = configuration.tabURLs.map { url in
                (
                    url,
                    webViewConfigurationForExtensionRequestedBrowserURL(url, for: extensionContext)
                )
            }
        }
        return openNormalBrowserWindow(
            requestedTabs: requestedTabs,
            shouldFocus: configuration.shouldBeFocused,
            requestedFrame: configuration.frame,
            requestedWindowState: configuration.windowState,
            extensionContext: extensionContext
        )
    }
    func openNormalBrowserWindow(
        requestedTabs: [(url: URL?, webViewConfiguration: WKWebViewConfiguration?)],
        shouldFocus: Bool,
        requestedFrame: CGRect = .null,
        requestedWindowState: WKWebExtension.WindowState = .normal,
        extensionContext: WKWebExtensionContext? = nil
    ) -> BrowserWebExtensionWindowAdapter? {
        guard let appDelegate = AppDelegate.shared else { return nil }
        let windowID = appDelegate.createMainWindow(
            shouldActivate: shouldFocus,
            allowsStartupSessionRestore: false
        )
        var didSucceed = false
        defer {
            if !didSucceed {
                _ = appDelegate.closeMainWindow(windowId: windowID, recordHistory: false)
            }
        }
        guard let tabManager = appDelegate.tabManagerFor(windowId: windowID) else { return nil }
        guard let workspace = tabManager.selectedWorkspace ?? tabManager.tabs.first else { return nil }
        let bootstrapPanelIDs = Array(workspace.panels.keys)
        var openedAdapters: [BrowserWebExtensionTabAdapter] = []
        for (index, requestedTab) in requestedTabs.enumerated() {
            guard let adapter = openBrowserTab(
                in: tabManager,
                url: requestedTab.url,
                shouldActivate: index == 0,
                webViewConfiguration: requestedTab.webViewConfiguration
            ) else { return nil }
            openedAdapters.append(adapter)
        }
        for panelID in bootstrapPanelIDs {
            _ = workspace.closePanel(panelID, force: true)
        }
        guard let firstPanelID = openedAdapters.first?.panel?.id,
              let window = windowAdapter(for: firstPanelID) else { return nil }
        if let extensionContext {
            window.markExtensionCreated(
                by: extensionContext,
                windowID: windowID,
                panelIDs: Set(openedAdapters.compactMap { $0.panel?.id })
            )
        }
        window.applyInitialConfiguration(
            requestedFrame: requestedFrame,
            windowState: requestedWindowState
        )
        didSucceed = true
        return window
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

        let webViewConfiguration = configuration.url.flatMap {
            webViewConfigurationForExtensionRequestedBrowserURL($0, for: extensionContext)
        }
        let adapter: BrowserWebExtensionTabAdapter?
        if let requestedWindow = configuration.window {
            guard let requestedWindow = requestedWindow as? BrowserWebExtensionWindowAdapter,
                  let hostWindow = requestedWindow.hostWindow,
                  let tabManager = AppDelegate.shared?.contextForMainTerminalWindow(hostWindow)?.tabManager else {
                completionHandler(nil, openTabsUnsupportedError())
                return
            }
            let preparedExtensionPanel = requestedWindow.prepareToCreateExtensionPanel(for: extensionContext)
            adapter = openBrowserTab(
                in: tabManager,
                url: configuration.url,
                shouldActivate: configuration.shouldBeActive,
                webViewConfiguration: webViewConfiguration
            )
            requestedWindow.finishCreatingExtensionPanel(
                panelID: adapter?.panel?.id,
                wasPrepared: preparedExtensionPanel
            )
        } else {
            let implicitWindow = implicitTabCreationSourcePanel()
                .flatMap { windowAdapter(for: $0.id) }
            let preparedExtensionPanel = implicitWindow?
                .prepareToCreateExtensionPanel(for: extensionContext) == true
            adapter = openBrowserTab(
                url: configuration.url,
                shouldActivate: configuration.shouldBeActive,
                webViewConfiguration: webViewConfiguration
            )
            implicitWindow?.finishCreatingExtensionPanel(
                panelID: adapter?.panel?.id,
                wasPrepared: preparedExtensionPanel
            )
        }
        guard let adapter else {
            completionHandler(nil, openTabsUnsupportedError())
            return
        }
        completionHandler(adapter, nil)
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

    func permissionMessage(
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

    func confirmPermissionRequest(informativeText: String) -> Bool {
        if let permissionConfirmation {
            return permissionConfirmation(informativeText)
        }
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
