import AppKit
import Bonsplit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit


// MARK: - Context menu construction, item recognition, and actions
extension CmuxWebView {
    private static let browserFocusModeContextMenuItemIdentifier =
        NSUserInterfaceItemIdentifier("cmux.browserFocusMode.toggle")
    private final class ContextMenuFallbackBox: NSObject {
        weak var target: AnyObject?
        let action: Selector?

        init(target: AnyObject?, action: Selector?) {
            self.target = target
            self.action = action
        }
    }

    private static var contextMenuFallbackKey: UInt8 = 0
    static func makeContextDownloadTraceID(prefix: String) -> String {
#if DEBUG
        return "\(prefix)-\(UUID().uuidString.prefix(8))"
#else
        return prefix
#endif
    }

    func debugContextDownload(_ message: @autoclosure () -> String) {
#if DEBUG
        cmuxDebugLog(Self.redactedContextDownloadDebugMessage(message()))
#endif
    }

    #if DEBUG
    private static let contextDownloadFieldPattern = try! NSRegularExpression(
        pattern: "(^| )([A-Za-z][A-Za-z0-9_-]*)=",
        options: []
    )

    private static func redactedContextDownloadDebugMessage(_ message: String) -> String {
        let nsMessage = message as NSString
        let fullRange = NSRange(location: 0, length: nsMessage.length)
        let matches = contextDownloadFieldPattern.matches(in: message, range: fullRange)
        guard !matches.isEmpty else { return message }

        var result = ""
        var cursor = 0
        var matchIndex = 0

        while matchIndex < matches.count {
            let match = matches[matchIndex]
            let fieldStart = match.range.location
            if cursor < fieldStart {
                result += nsMessage.substring(
                    with: NSRange(location: cursor, length: fieldStart - cursor)
                )
            }

            let separatorRange = match.range(at: 1)
            if separatorRange.length > 0 {
                result += " "
            }

            let keyRange = match.range(at: 2)
            let key = nsMessage.substring(with: keyRange)
            let valueStart = match.range.location + match.range.length
            let sensitive = shouldRedactContextDownloadField(key)
            let valueEnd: Int

            if sensitive && key.lowercased() == "payload" {
                valueEnd = nsMessage.length
                matchIndex = matches.count
            } else {
                valueEnd = matchIndex + 1 < matches.count
                    ? matches[matchIndex + 1].range.location
                    : nsMessage.length
                matchIndex += 1
            }

            let valueLength = max(0, valueEnd - valueStart)
            let value = nsMessage.substring(with: NSRange(location: valueStart, length: valueLength))

            if sensitive {
                result += "\(key)=\(redactedContextDownloadValue(key: key, value: value))"
            } else {
                result += nsMessage.substring(
                    with: NSRange(location: keyRange.location, length: valueEnd - keyRange.location)
                )
            }

            cursor = valueEnd
        }

        if cursor < nsMessage.length {
            result += nsMessage.substring(
                with: NSRange(location: cursor, length: nsMessage.length - cursor)
            )
        }

        return result
    }

    private static func shouldRedactContextDownloadField(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized == "referer" ||
            normalized == "path" ||
            normalized == "payload" ||
            normalized.hasSuffix("url")
    }

    private static func redactedContextDownloadValue(key: String, value: String) -> String {
        guard value != "nil", !value.isEmpty else { return value }

        if shouldTreatContextDownloadFieldAsURL(key),
           let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           !scheme.isEmpty {
            switch scheme {
            case "http", "https":
                return "\(scheme)://\(url.host ?? "unknown")"
            case "data":
                return "data:<redacted>"
            case "file":
                return "file:<redacted>"
            default:
                return "\(scheme):<redacted>"
            }
        }

        return "<redacted>"
    }

    private static func shouldTreatContextDownloadFieldAsURL(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized == "referer" || normalized.hasSuffix("url")
    }
    #endif

    static func selectorName(_ selector: Selector?) -> String {
        guard let selector else { return "nil" }
        return NSStringFromSelector(selector)
    }

    private func debugLogContextMenuDownloadCandidate(_ item: NSMenuItem, index: Int) {
        let identifier = item.identifier?.rawValue ?? "nil"
        let title = item.title
        let actionName = Self.selectorName(item.action)
        let idToken = Self.normalizedContextMenuToken(identifier)
        let titleToken = Self.normalizedContextMenuToken(title)
        let actionToken = Self.normalizedContextMenuToken(actionName)
        guard idToken.contains("download")
            || titleToken.contains("download")
            || actionToken.contains("download") else {
            return
        }
        debugContextDownload(
            "browser.ctxdl.menu item index=\(index) id=\(identifier) title=\(title) action=\(actionName)"
        )
    }

    private static func normalizedContextMenuToken(_ value: String?) -> String {
        guard let value else { return "" }
        let lowered = value.lowercased()
        let alphanumerics = CharacterSet.alphanumerics
        let scalars = lowered.unicodeScalars.filter { alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private func isDownloadImageMenuItem(_ item: NSMenuItem) -> Bool {
        let identifier = Self.normalizedContextMenuToken(item.identifier?.rawValue)
        if identifier.contains("downloadimage") {
            return true
        }

        let title = Self.normalizedContextMenuToken(item.title)
        if title.contains("downloadimage") {
            return true
        }

        if let action = item.action {
            let actionName = Self.normalizedContextMenuToken(NSStringFromSelector(action))
            if actionName.contains("downloadimage") {
                return true
            }
        }

        return false
    }

    private func isDownloadLinkedFileMenuItem(_ item: NSMenuItem) -> Bool {
        let identifier = Self.normalizedContextMenuToken(item.identifier?.rawValue)
        if identifier.contains("downloadlinkedfile")
            || identifier.contains("downloadlinktodisk") {
            return true
        }

        let title = Self.normalizedContextMenuToken(item.title)
        if title.contains("downloadlinkedfile")
            || title.contains("downloadlinktodisk") {
            return true
        }

        if let action = item.action {
            let actionName = Self.normalizedContextMenuToken(NSStringFromSelector(action))
            if actionName.contains("downloadlinkedfile")
                || actionName.contains("downloadlinktodisk") {
                return true
            }
        }

        return false
    }

    private func isCopyImageMenuItem(_ item: NSMenuItem) -> Bool {
        let tokens = [
            Self.normalizedContextMenuToken(item.identifier?.rawValue),
            Self.normalizedContextMenuToken(item.title),
            item.action.map { Self.normalizedContextMenuToken(NSStringFromSelector($0)) } ?? "",
        ]

        for token in tokens where !token.isEmpty {
            if token.contains("copyimageaddress")
                || token.contains("copyimageurl")
                || token.contains("copyimagelocation") {
                return false
            }
            if token == "copyimage"
                || token.contains("copyimagetoclipboard")
                || token.contains("copyimage") {
                return true
            }
        }

        return false
    }

    func isDownloadableScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    func isDataURLScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "data"
    }

    func isDownloadSupportedScheme(_ url: URL) -> Bool {
        return isDownloadableScheme(url) || isDataURLScheme(url)
    }

    private func isOurContextMenuAction(target: AnyObject?, action: Selector?) -> Bool {
        guard target === self else { return false }
        if action == #selector(contextMenuToggleBrowserFocusMode(_:)) {
            return true
        }
        if action == #selector(contextMenuCopyImage(_:)) {
            return true
        }
        return action == #selector(contextMenuDownloadImage(_:))
            || action == #selector(contextMenuDownloadLinkedFile(_:))
    }

    private func captureFallbackForMenuItemIfNeeded(_ item: NSMenuItem) {
        let target = item.target as AnyObject?
        let action = item.action
        if isOurContextMenuAction(target: target, action: action) {
            return
        }
        let box = ContextMenuFallbackBox(target: target, action: action)
        objc_setAssociatedObject(
            item,
            &Self.contextMenuFallbackKey,
            box,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func fallbackFromSender(
        _ sender: Any?,
        defaultAction: Selector?,
        defaultTarget: AnyObject?
    ) -> (action: Selector?, target: AnyObject?) {
        if let item = sender as? NSMenuItem,
           let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
            return (box.action, box.target)
        }
        return (defaultAction, defaultTarget)
    }

    private func resolveContextMenuLinkURL(at point: NSPoint, completion: @escaping (URL?) -> Void) {
        if let contextMenuLinkURLProvider {
            contextMenuLinkURLProvider(self, point, completion)
            return
        }
        findLinkURLAtPoint(point, completion: completion)
    }

    private func canOpenInDefaultBrowser(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https"
    }

    private func openContextMenuLinkInDefaultBrowser(_ url: URL) {
        if let contextMenuDefaultBrowserOpener {
            _ = contextMenuDefaultBrowserOpener(url)
            return
        }
        _ = NSWorkspace.shared.open(url)
    }

    private func appendBrowserFocusModeContextMenuItem(to menu: NSMenu) {
        let state = AppDelegate.shared?.browserFocusModeContextMenuState(for: self) ?? (isActive: false, canToggle: false)
        guard state.isActive || state.canToggle else { return }

        let title = state.isActive
            ? String(localized: "browser.focusMode.context.exit", defaultValue: "Exit Browser Focus Mode")
            : String(localized: "browser.focusMode.context.enter", defaultValue: "Enter Browser Focus Mode")
        if let item = menu.items.first(where: { $0.identifier == Self.browserFocusModeContextMenuItemIdentifier }) {
            item.title = title
            item.target = self
            item.action = #selector(contextMenuToggleBrowserFocusMode(_:))
            item.state = state.isActive ? NSControl.StateValue.on : NSControl.StateValue.off
            return
        }

        if menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: title,
            action: #selector(contextMenuToggleBrowserFocusMode(_:)),
            keyEquivalent: ""
        )
        item.identifier = Self.browserFocusModeContextMenuItemIdentifier
        item.target = self
        item.state = state.isActive ? NSControl.StateValue.on : NSControl.StateValue.off
        menu.addItem(item)
    }

    func runContextMenuFallback(
        action: Selector?,
        target: AnyObject?,
        sender: Any?,
        traceID: String? = nil,
        reason: String? = nil
    ) {
        let trace = traceID ?? "unknown"
        guard let action else {
            debugContextDownload(
                "browser.ctxdl.fallback trace=\(trace) reason=\(reason ?? "none") action=nil target=\(String(describing: target))"
            )
            return
        }
        // Guard against accidental self-recursion if fallback gets overwritten.
        if isOurContextMenuAction(target: target, action: action) {
            debugContextDownload(
                "browser.ctxdl.fallback trace=\(trace) reason=\(reason ?? "none") skipped=recursive action=\(Self.selectorName(action))"
            )
            return
        }
        let dispatched = NSApp.sendAction(action, to: target, from: sender)
        debugContextDownload(
            "browser.ctxdl.fallback trace=\(trace) reason=\(reason ?? "none") dispatched=\(dispatched ? 1 : 0) action=\(Self.selectorName(action)) target=\(String(describing: target))"
        )
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        lastContextMenuPoint = convert(event.locationInWindow, from: nil)
        debugContextDownload(
            "browser.ctxdl.menu open itemCount=\(menu.items.count) point=(\(Int(lastContextMenuPoint.x)),\(Int(lastContextMenuPoint.y)))"
        )
        var openLinkInsertionIndex: Int?
        var hasDefaultBrowserOpenLinkItem = false

        for (index, item) in menu.items.enumerated() {
            debugLogContextMenuDownloadCandidate(item, index: index)
            if !hasDefaultBrowserOpenLinkItem,
               (item.action == #selector(contextMenuOpenLinkInDefaultBrowser(_:))
                || item.title == String(localized: "browser.contextMenu.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser")) {
                hasDefaultBrowserOpenLinkItem = true
            }

            if openLinkInsertionIndex == nil,
               (item.identifier?.rawValue == "WKMenuItemIdentifierOpenLink"
                || item.title == "Open Link") {
                openLinkInsertionIndex = index + 1
            }

            // Retarget "Open Link in New Window" to open as a tab, not a popup.
            // Without this, WebKit's default action calls createWebViewWith with
            // navigationType .other, which our classifier would treat as a scripted
            // popup request.
            if item.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow"
                || item.title.contains("Open Link in New Window") {
                item.title = String(localized: "browser.contextMenu.openLinkInNewTab", defaultValue: "Open Link in New Tab")
                item.target = self
                item.action = #selector(contextMenuOpenLinkInNewTab(_:))
            }

            if isDownloadImageMenuItem(item) {
                debugContextDownload(
                    "browser.ctxdl.menu hook kind=image index=\(index) id=\(item.identifier?.rawValue ?? "nil") title=\(item.title) action=\(Self.selectorName(item.action))"
                )
                captureFallbackForMenuItemIfNeeded(item)
                // Keep global fallback as a secondary safety net.
                if let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
                    fallbackDownloadImageTarget = box.target
                    fallbackDownloadImageAction = box.action
                } else if !isOurContextMenuAction(target: item.target as AnyObject?, action: item.action) {
                    fallbackDownloadImageTarget = item.target as AnyObject?
                    fallbackDownloadImageAction = item.action
                }
                item.target = self
                item.action = #selector(contextMenuDownloadImage(_:))
            }

            if isCopyImageMenuItem(item) {
                debugContextDownload(
                    "browser.ctxcopy.menu hook kind=image index=\(index) id=\(item.identifier?.rawValue ?? "nil") title=\(item.title) action=\(Self.selectorName(item.action))"
                )
                captureFallbackForMenuItemIfNeeded(item)
                if let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
                    fallbackCopyImageTarget = box.target
                    fallbackCopyImageAction = box.action
                } else if !isOurContextMenuAction(target: item.target as AnyObject?, action: item.action) {
                    fallbackCopyImageTarget = item.target as AnyObject?
                    fallbackCopyImageAction = item.action
                }
                item.target = self
                item.action = #selector(contextMenuCopyImage(_:))
            }

            if isDownloadLinkedFileMenuItem(item) {
                debugContextDownload(
                    "browser.ctxdl.menu hook kind=linked index=\(index) id=\(item.identifier?.rawValue ?? "nil") title=\(item.title) action=\(Self.selectorName(item.action))"
                )
                captureFallbackForMenuItemIfNeeded(item)
                // Keep global fallback as a secondary safety net.
                if let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
                    fallbackDownloadLinkedFileTarget = box.target
                    fallbackDownloadLinkedFileAction = box.action
                } else if !isOurContextMenuAction(target: item.target as AnyObject?, action: item.action) {
                    fallbackDownloadLinkedFileTarget = item.target as AnyObject?
                    fallbackDownloadLinkedFileAction = item.action
                }
                item.target = self
                item.action = #selector(contextMenuDownloadLinkedFile(_:))
            }
        }

        if let openLinkInsertionIndex, !hasDefaultBrowserOpenLinkItem {
            let item = NSMenuItem(
                title: String(localized: "browser.contextMenu.openLinkInDefaultBrowser", defaultValue: "Open Link in Default Browser"),
                action: #selector(contextMenuOpenLinkInDefaultBrowser(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.insertItem(item, at: min(openLinkInsertionIndex, menu.items.count))
        }
        appendScreenshotContextMenuItems(to: menu)
        appendMoveTabToNewWorkspaceContextMenuItem(to: menu)
        appendBrowserFocusModeContextMenuItem(to: menu)
    }

    @objc private func contextMenuToggleBrowserFocusMode(_ sender: Any?) {
        _ = sender
        if AppDelegate.shared?.toggleBrowserFocusModeFromContextMenu(for: self) != true {
            NSSound.beep()
        }
    }

    @objc private func contextMenuOpenLinkInDefaultBrowser(_ sender: Any?) {
        _ = sender
        let point = lastContextMenuPoint
        resolveContextMenuLinkURL(at: point) { [weak self] url in
            guard let self, let url, self.canOpenInDefaultBrowser(url) else { return }
            self.openContextMenuLinkInDefaultBrowser(url)
        }
    }

    @objc private func contextMenuOpenLinkInNewTab(_ sender: Any?) {
        let point = lastContextMenuPoint
        resolveContextMenuLinkURL(at: point) { [weak self] url in
            guard let self, let url else { return }
            self.onContextMenuOpenLinkInNewTab?(url)
        }
    }

}
