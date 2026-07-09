import AppKit
import WebKit

@available(macOS 15.4, *)
extension BrowserWebExtensionSupport: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        let openWindows: [any WKWebExtensionWindow] = [windowAdapter] + popouts(for: extensionContext)
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
        popouts(for: extensionContext).first(where: \.isKeyWindow) ?? windowAdapter
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
        let popout = BrowserWebExtensionPopoutWindowController(
            configuration: configuration,
            context: extensionContext,
            support: self
        )
        popouts.append(popout)
        controller.didOpenWindow(popout)
        controller.didOpenTab(popout.tab)
        completionHandler(popout, nil)
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
           !canOpenInRegularBrowserTab(url),
           controller.extensionContext(for: url) == nil {
            completionHandler(nil, openTabsUnsupportedError())
            return
        }

        guard let adapter = openBrowserTab(
            url: configuration.url,
            shouldActivate: configuration.shouldBeActive,
            webViewConfiguration: nil
        ) else {
            completionHandler(nil, openTabsUnsupportedError())
            return
        }
        completionHandler(adapter, nil)
    }

    private func openBrowserTab(
        url: URL?,
        shouldActivate: Bool,
        webViewConfiguration: WKWebViewConfiguration?
    ) -> BrowserWebExtensionTabAdapter? {
        guard let sourcePanel = activeTabAdapter?.panel else { return nil }
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
        return nil
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

    private func dockContainingPanel(_ panelID: UUID) -> DockSplitStore? {
        DockSplitStore.liveStores.first { $0.containsPanel(panelID) }
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
        refreshActionSnapshot(for: context)
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
