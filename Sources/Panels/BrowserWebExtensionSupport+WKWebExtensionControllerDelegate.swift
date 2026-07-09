import AppKit
import WebKit

@available(macOS 15.4, *)
extension BrowserWebExtensionSupport: WKWebExtensionControllerDelegate {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        [windowAdapter] + popouts
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        popouts.first(where: \.isKeyWindow) ?? windowAdapter
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
        if let url = configuration.url, url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
            completionHandler(nil, nil)
            return
        }
        completionHandler(nil, NSError(
            domain: "cmux.webExtension",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: String(
                localized: "browser.webExtension.error.openTabsUnsupported",
                defaultValue: "Opening extension tabs is not supported yet."
            )]
        ))
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
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        // Native messaging (e.g. Bitwarden's desktop-app biometrics IPC) is not
        // bridged. Never resolve the reply: an error reply sends Bitwarden into
        // an unthrottled reconnect loop (observed ~175k messages/sec), while an
        // unresolved promise parks the caller harmlessly.
        nativeMessageDropCount += 1
        if nativeMessageDropCount <= 5 {
#if DEBUG
            cmuxDebugLog(
                "browser.webext.nativeMessage dropped app=\(applicationIdentifier ?? "nil") " +
                "count=\(nativeMessageDropCount)"
            )
#endif
        }
        _ = replyHandler
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // See sendMessage above: leave the native port unresolved rather than
        // erroring, so extensions do not retry-loop.
#if DEBUG
        cmuxDebugLog("browser.webext.nativeConnect dropped app=\(port.applicationIdentifier ?? "nil")")
#endif
        _ = completionHandler
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
    }

    private func permissionMessage(
        extensionContext: WKWebExtensionContext,
        details: String,
        key: String.LocalizationValue,
        defaultValue: String.LocalizationValue
    ) -> String {
        let extensionName = extensionContext.webExtension.displayName ?? String(
            localized: "browser.webExtension.action.help",
            defaultValue: "Extension"
        )
        return String(
            format: String(localized: key, defaultValue: defaultValue),
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
