import AppKit
import Bonsplit
import ObjectiveC
import WebKit

/// WKWebView tends to consume some Command-key equivalents (e.g. Cmd+N/Cmd+W),
/// preventing the app menu/SwiftUI Commands from receiving them. Route menu
/// key equivalents first so app-level shortcuts continue to work when WebKit is
/// the first responder.
final class CmuxWebView: WKWebView {
    private final class ContextMenuFallbackBox: NSObject {
        weak var target: AnyObject?
        let action: Selector?

        init(target: AnyObject?, action: Selector?) {
            self.target = target
            self.action = action
        }
    }

    private static var contextMenuFallbackKey: UInt8 = 0

    var onContextMenuDownloadStateChanged: ((Bool) -> Void)?
    var contextMenuLinkURLProvider: ((CmuxWebView, NSPoint, @escaping (URL?) -> Void) -> Void)?
    var contextMenuDefaultBrowserOpener: ((URL) -> Bool)?
    /// Guard against background panes stealing first responder (e.g. page autofocus).
    /// BrowserPanelView updates this as pane focus state changes.
    var allowsFirstResponderAcquisition: Bool = true
    private var pointerFocusAllowanceDepth: Int = 0
    var allowsFirstResponderAcquisitionEffective: Bool {
        allowsFirstResponderAcquisition || pointerFocusAllowanceDepth > 0
    }
    var debugPointerFocusAllowanceDepth: Int { pointerFocusAllowanceDepth }

    override func becomeFirstResponder() -> Bool {
        guard allowsFirstResponderAcquisitionEffective else {
#if DEBUG
            let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
            dlog(
                "browser.focus.blockedBecome web=\(ObjectIdentifier(self)) " +
                "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
                "pointerDepth=\(pointerFocusAllowanceDepth) eventType=\(eventType)"
            )
#endif
            return false
        }
        let result = super.becomeFirstResponder()
        if result {
            NotificationCenter.default.post(name: .browserDidBecomeFirstResponderWebView, object: self)
        }
#if DEBUG
        let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil"
        dlog(
            "browser.focus.become web=\(ObjectIdentifier(self)) result=\(result ? 1 : 0) " +
            "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
            "pointerDepth=\(pointerFocusAllowanceDepth) eventType=\(eventType)"
        )
#endif
        return result
    }

    /// Temporarily permits focus acquisition for explicit pointer-driven interactions
    /// (mouse click into this webview) while keeping background autofocus blocked.
    func withPointerFocusAllowance(_ body: () -> Void) {
        pointerFocusAllowanceDepth += 1
#if DEBUG
        dlog(
            "browser.focus.pointerAllowance.enter web=\(ObjectIdentifier(self)) " +
            "depth=\(pointerFocusAllowanceDepth)"
        )
#endif
        defer {
            pointerFocusAllowanceDepth = max(0, pointerFocusAllowanceDepth - 1)
#if DEBUG
            dlog(
                "browser.focus.pointerAllowance.exit web=\(ObjectIdentifier(self)) " +
                "depth=\(pointerFocusAllowanceDepth)"
            )
#endif
        }
        body()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Preserve Cmd+Return/Enter for web content (e.g. editors/forms). Do not
        // route it through app/menu key equivalents, which can trigger unintended actions.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            return false
        }

        // Let the app menu handle key equivalents first (New Tab, Close Tab, tab switching, etc).
        if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
            return true
        }

        // Handle app-level shortcuts that are not menu-backed (for example split commands).
        // Without this, WebKit can consume Cmd-based shortcuts before the app monitor sees them.
        if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Some Cmd-based key paths in WebKit don't consistently invoke performKeyEquivalent.
        // Route them through the same app-level shortcut handler as a fallback.
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
            return
        }

        super.keyDown(with: event)
    }

    // MARK: - Focus on click

    // The SwiftUI Color.clear overlay (.onTapGesture) that focuses panes can't receive
    // clicks when a WKWebView is underneath — AppKit delivers the click to the deepest
    // NSView (WKWebView), not to sibling SwiftUI overlays. Notify the panel system so
    // bonsplit focus tracks which pane the user clicked in.
    override func mouseDown(with event: NSEvent) {
#if DEBUG
        let windowNumber = window?.windowNumber ?? -1
        let firstResponderType = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        dlog(
            "browser.focus.mouseDown web=\(ObjectIdentifier(self)) " +
            "policy=\(allowsFirstResponderAcquisition ? 1 : 0) " +
            "pointerDepth=\(pointerFocusAllowanceDepth) win=\(windowNumber) fr=\(firstResponderType)"
        )
#endif
        NotificationCenter.default.post(name: .webViewDidReceiveClick, object: self)
        withPointerFocusAllowance {
            super.mouseDown(with: event)
        }
    }

    // MARK: - Mouse back/forward buttons & middle-click

    override func otherMouseDown(with event: NSEvent) {
        // Button 3 = back, button 4 = forward (multi-button mice like Logitech).
        // Consume the event so WebKit doesn't handle it.
        switch event.buttonNumber {
        case 3:
            goBack()
            return
        case 4:
            goForward()
            return
        default:
            break
        }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        // Middle-click (button 2) on a link opens it in a new tab.
        if event.buttonNumber == 2 {
            let point = convert(event.locationInWindow, from: nil)
            findLinkAtPoint(point) { [weak self] url in
                guard let self, let url else { return }
                NotificationCenter.default.post(
                    name: .webViewMiddleClickedLink,
                    object: self,
                    userInfo: ["url": url]
                )
            }
            return
        }
        super.otherMouseUp(with: event)
    }

    /// Use JavaScript to find the nearest anchor element at the given view-local point.
    private func findLinkAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        // WKWebView's coordinate system is flipped (origin top-left for web content).
        let flippedY = bounds.height - point.y
        let js = """
        (() => {
            let el = document.elementFromPoint(\(point.x), \(flippedY));
            while (el) {
                if (el.tagName === 'A' && el.href) return el.href;
                el = el.parentElement;
            }
            return '';
        })();
        """
        evaluateJavaScript(js) { result, _ in
            guard let href = result as? String, !href.isEmpty,
                  let url = URL(string: href) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    // MARK: - Context menu download support

    /// The last context-menu point in view coordinates.
    private var lastContextMenuPoint: NSPoint = .zero
    /// Saved native WebKit action for "Download Image".
    private var fallbackDownloadImageTarget: AnyObject?
    private var fallbackDownloadImageAction: Selector?
    /// Saved native WebKit action for "Download Linked File".
    private var fallbackDownloadLinkedFileTarget: AnyObject?
    private var fallbackDownloadLinkedFileAction: Selector?

    private func isDownloadableScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    private func isOurDownloadMenuAction(target: AnyObject?, action: Selector?) -> Bool {
        guard target === self else { return false }
        return action == #selector(contextMenuDownloadImage(_:))
            || action == #selector(contextMenuDownloadLinkedFile(_:))
    }

    private func resolveGoogleRedirectURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), host.contains("google.") else { return nil }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = comps.queryItems else { return nil }
        let map = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name.lowercased(), $0.value ?? "") })
        let candidates = ["imgurl", "mediaurl", "url", "q"]
        for key in candidates {
            guard let raw = map[key], !raw.isEmpty,
                  let decoded = raw.removingPercentEncoding ?? raw as String?,
                  let candidate = URL(string: decoded),
                  isDownloadableScheme(candidate) else {
                continue
            }
            return candidate
        }
        // Some links are wrapped as /url?...
        if comps.path.lowercased() == "/url" {
            for key in ["url", "q"] {
                if let raw = map[key], let candidate = URL(string: raw), isDownloadableScheme(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func normalizedLinkedDownloadURL(_ url: URL) -> URL {
        resolveGoogleRedirectURL(url) ?? url
    }

    private func captureFallbackForMenuItemIfNeeded(_ item: NSMenuItem) {
        let target = item.target as AnyObject?
        let action = item.action
        if isOurDownloadMenuAction(target: target, action: action) {
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

    private func fallbackFromSender(
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

    /// Resolve the topmost image URL near a point, accounting for overlay layers.
    private func findImageURLAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let flippedY = bounds.height - point.y
        let js = """
        (() => {
            const nodes = document.elementsFromPoint(\(point.x), \(flippedY));
            for (const start of nodes) {
                let elChain = [];
                let seen = new Set();
                let walk = (node) => {
                    let chain = [];
                    let localSeen = new Set();
                    let visit = (n) => {
                        while (n && !localSeen.has(n)) {
                            localSeen.add(n);
                            chain.push(n);
                            n = n.parentElement;
                        }
                    };
                    visit(node);
                    if (node && node.tagName === 'PICTURE') {
                        const img = node.querySelector('img');
                        if (img) visit(img);
                    }
                    return chain;
                };
                for (const el of walk(start)) {
                    if (!seen.has(el)) {
                        seen.add(el);
                        elChain.push(el);
                    }
                }

                for (const el of elChain) {
                    if (el.tagName === 'IMG') {
                        if (el.currentSrc) return el.currentSrc;
                        if (el.src) return el.src;
                    }
                    if (el.tagName === 'PICTURE') {
                        const img = el.querySelector('img');
                        if (img) {
                            if (img.currentSrc) return img.currentSrc;
                            if (img.src) return img.src;
                        }
                    }
                }
            }
            return '';
        })();
        """
        evaluateJavaScript(js) { result, _ in
            guard let src = result as? String, !src.isEmpty,
                  let url = URL(string: src) else {
                completion(nil)
                return
            }
            completion(url)
        }
    }

    /// Resolve the topmost link URL near a point, accounting for overlay layers.
    private func findLinkURLAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let flippedY = bounds.height - point.y
        let js = """
        (() => {
            const nodes = document.elementsFromPoint(\(point.x), \(flippedY));
            for (const start of nodes) {
                let el = start;
                let seen = new Set();
                let cur = (() => {
                    let n = start;
                    return n;
                })();
                let walk = (node) => {
                    let chain = [];
                    while (node && !seen.has(node)) {
                        seen.add(node);
                        chain.push(node);
                        node = node.parentElement;
                    }
                    return chain;
                };
                for (const n of walk(cur)) {
                    if (n.tagName === 'A' && n.href) return n.href;
                }
            }
            return '';
        })();
        """
        evaluateJavaScript(js) { result, _ in
            guard let href = result as? String, !href.isEmpty,
                  let url = URL(string: href) else {
                completion(nil)
                return
            }
            completion(url)
        }
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

    private func runContextMenuFallback(action: Selector?, target: AnyObject?, sender: Any?) {
        guard let action else { return }
        // Guard against accidental self-recursion if fallback gets overwritten.
        if target === self,
           action == #selector(contextMenuDownloadImage(_:))
            || action == #selector(contextMenuDownloadLinkedFile(_:)) {
            NSLog("CmuxWebView context fallback skipped (recursive self action)")
            return
        }
        _ = NSApp.sendAction(action, to: target, from: sender)
    }

    private func notifyContextMenuDownloadState(_ downloading: Bool) {
        if Thread.isMainThread {
            onContextMenuDownloadStateChanged?(downloading)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onContextMenuDownloadStateChanged?(downloading)
            }
        }
    }

    private func downloadURLViaSession(
        _ url: URL,
        suggestedFilename: String?,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?
    ) {
        guard isDownloadableScheme(url) else {
            runContextMenuFallback(action: fallbackAction, target: fallbackTarget, sender: sender)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        notifyContextMenuDownloadState(true)

        if scheme == "file" {
            DispatchQueue.main.async {
                do {
                    let data = try Data(contentsOf: url)
                    let filename = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let saveName = (filename?.isEmpty == false ? filename! : url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
                    let savePanel = NSSavePanel()
                    savePanel.nameFieldStringValue = saveName
                    savePanel.canCreateDirectories = true
                    savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    // Download is already complete; we're now waiting for user save choice.
                    self.notifyContextMenuDownloadState(false)
                    savePanel.begin { result in
                        guard result == .OK, let destURL = savePanel.url else { return }
                        try? data.write(to: destURL, options: .atomic)
                    }
                } catch {
                    self.notifyContextMenuDownloadState(false)
                    self.runContextMenuFallback(action: fallbackAction, target: fallbackTarget, sender: sender)
                }
            }
            return
        }

        let cookieStore = configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
            for (key, value) in cookieHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let referer = self.url?.absoluteString, !referer.isEmpty {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            if let ua = self.customUserAgent, !ua.isEmpty {
                request.setValue(ua, forHTTPHeaderField: "User-Agent")
            }

            URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    guard let data, error == nil else {
                        self.notifyContextMenuDownloadState(false)
                        self.runContextMenuFallback(action: fallbackAction, target: fallbackTarget, sender: sender)
                        return
                    }
                    let filenameCandidate = suggestedFilename
                        ?? response?.suggestedFilename
                        ?? url.lastPathComponent
                    let saveName = filenameCandidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "download" : filenameCandidate

                    let savePanel = NSSavePanel()
                    savePanel.nameFieldStringValue = saveName
                    savePanel.canCreateDirectories = true
                    savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    // Download is already complete; we're now waiting for user save choice.
                    self.notifyContextMenuDownloadState(false)
                    savePanel.begin { result in
                        guard result == .OK, let destURL = savePanel.url else { return }
                        do {
                            try data.write(to: destURL, options: .atomic)
                        } catch {
                            self.runContextMenuFallback(action: fallbackAction, target: fallbackTarget, sender: sender)
                        }
                    }
                }
            }.resume()
        }
    }

    private func startContextMenuDownload(
        _ url: URL,
        sender: Any?,
        fallbackAction: Selector?,
        fallbackTarget: AnyObject?
    ) {
        NSLog("CmuxWebView context download start: %@", url.absoluteString)
        downloadURLViaSession(
            url,
            suggestedFilename: nil,
            sender: sender,
            fallbackAction: fallbackAction,
            fallbackTarget: fallbackTarget
        )
    }

    // MARK: - Drag-and-drop passthrough

    // WKWebView inherently calls registerForDraggedTypes with public.text (and others).
    // Bonsplit tab drags use NSString (public.utf8-plain-text) which conforms to public.text,
    // so AppKit's view-hierarchy-based drag routing delivers the session to WKWebView instead
    // of SwiftUI's sibling .onDrop overlays. Rejecting in draggingEntered doesn't help because
    // AppKit only bubbles up through superviews, not siblings.
    //
    // Fix: filter out text-based types that conflict with bonsplit tab drags, but keep
    // file URL types so Finder file drops and HTML drag-and-drop work.
    private static let blockedDragTypes: Set<NSPasteboard.PasteboardType> = [
        .string, // public.utf8-plain-text — matches bonsplit's NSString tab drags
        NSPasteboard.PasteboardType("public.text"),
        NSPasteboard.PasteboardType("public.plain-text"),
        NSPasteboard.PasteboardType("com.splittabbar.tabtransfer"),
        NSPasteboard.PasteboardType("com.cmux.sidebar-tab-reorder"),
    ]

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        let filtered = newTypes.filter { !Self.blockedDragTypes.contains($0) }
        if !filtered.isEmpty {
            super.registerForDraggedTypes(filtered)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        lastContextMenuPoint = convert(event.locationInWindow, from: nil)
        var openLinkInsertionIndex: Int?
        var hasDefaultBrowserOpenLinkItem = false

        for (index, item) in menu.items.enumerated() {
            if !hasDefaultBrowserOpenLinkItem,
               (item.action == #selector(contextMenuOpenLinkInDefaultBrowser(_:))
                || item.title == "Open Link in Default Browser") {
                hasDefaultBrowserOpenLinkItem = true
            }

            if openLinkInsertionIndex == nil,
               (item.identifier?.rawValue == "WKMenuItemIdentifierOpenLink"
                || item.title == "Open Link") {
                openLinkInsertionIndex = index + 1
            }

            // Rename "Open Link in New Window" to "Open Link in New Tab".
            // The UIDelegate's createWebViewWith already handles the action
            // by opening the link as a new surface in the same pane.
            if item.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow"
                || item.title.contains("Open Link in New Window") {
                item.title = "Open Link in New Tab"
            }

            if item.identifier?.rawValue == "WKMenuItemIdentifierDownloadImage"
                || item.title == "Download Image" {
                NSLog("CmuxWebView context menu hook: download image")
                captureFallbackForMenuItemIfNeeded(item)
                // Keep global fallback as a secondary safety net.
                if let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
                    fallbackDownloadImageTarget = box.target
                    fallbackDownloadImageAction = box.action
                } else if !isOurDownloadMenuAction(target: item.target as AnyObject?, action: item.action) {
                    fallbackDownloadImageTarget = item.target as AnyObject?
                    fallbackDownloadImageAction = item.action
                }
                item.target = self
                item.action = #selector(contextMenuDownloadImage(_:))
            }

            if item.identifier?.rawValue == "WKMenuItemIdentifierDownloadLinkedFile"
                || item.title == "Download Linked File" {
                NSLog("CmuxWebView context menu hook: download linked file")
                captureFallbackForMenuItemIfNeeded(item)
                // Keep global fallback as a secondary safety net.
                if let box = objc_getAssociatedObject(item, &Self.contextMenuFallbackKey) as? ContextMenuFallbackBox {
                    fallbackDownloadLinkedFileTarget = box.target
                    fallbackDownloadLinkedFileAction = box.action
                } else if !isOurDownloadMenuAction(target: item.target as AnyObject?, action: item.action) {
                    fallbackDownloadLinkedFileTarget = item.target as AnyObject?
                    fallbackDownloadLinkedFileAction = item.action
                }
                item.target = self
                item.action = #selector(contextMenuDownloadLinkedFile(_:))
            }
        }

        if let openLinkInsertionIndex, !hasDefaultBrowserOpenLinkItem {
            let item = NSMenuItem(
                title: "Open Link in Default Browser",
                action: #selector(contextMenuOpenLinkInDefaultBrowser(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.insertItem(item, at: min(openLinkInsertionIndex, menu.items.count))
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

    @objc private func contextMenuDownloadImage(_ sender: Any?) {
        let point = lastContextMenuPoint
        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackDownloadImageAction,
            defaultTarget: fallbackDownloadImageTarget
        )
        findImageURLAtPoint(point) { [weak self] url in
            guard let self else { return }
            if let url {
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "http" || scheme == "https" || scheme == "file" {
                    NSLog("CmuxWebView context download image URL: %@", url.absoluteString)
                    self.startContextMenuDownload(
                        url,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target
                    )
                    return
                }
            }

            // Google Images and similar sites often expose blob:/data: image URLs.
            // If image URL is not directly downloadable, fall back to the nearby link URL.
            self.findLinkURLAtPoint(point) { linkURL in
                guard let linkURL else {
                    NSLog("CmuxWebView context download image: no downloadable image/link URL, using fallback action")
                    self.runContextMenuFallback(
                        action: fallback.action,
                        target: fallback.target,
                        sender: sender
                    )
                    return
                }
                let linkScheme = linkURL.scheme?.lowercased() ?? ""
                guard linkScheme == "http" || linkScheme == "https" || linkScheme == "file" else {
                    NSLog("CmuxWebView context download image: link URL not downloadable (%@), using fallback action", linkURL.absoluteString)
                    self.runContextMenuFallback(
                        action: fallback.action,
                        target: fallback.target,
                        sender: sender
                    )
                    return
                }

                NSLog("CmuxWebView context download image fallback to link URL: %@", linkURL.absoluteString)
                self.startContextMenuDownload(
                    linkURL,
                    sender: sender,
                    fallbackAction: fallback.action,
                    fallbackTarget: fallback.target
                )
            }
        }
    }

    @objc private func contextMenuDownloadLinkedFile(_ sender: Any?) {
        let point = lastContextMenuPoint
        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackDownloadLinkedFileAction,
            defaultTarget: fallbackDownloadLinkedFileTarget
        )
        findLinkURLAtPoint(point) { [weak self] url in
            guard let self else { return }
            if let url {
                let normalized = self.normalizedLinkedDownloadURL(url)
                if self.isDownloadableScheme(normalized) {
                    NSLog("CmuxWebView context download linked file URL: %@ (normalized=%@)", url.absoluteString, normalized.absoluteString)
                    self.startContextMenuDownload(
                        normalized,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target
                    )
                    return
                }
            }

            // Fallback 1: image URL under cursor (useful on image-heavy result pages).
            self.findImageURLAtPoint(point) { imageURL in
                if let imageURL, self.isDownloadableScheme(imageURL) {
                    NSLog("CmuxWebView context download linked file fallback image URL: %@", imageURL.absoluteString)
                    self.startContextMenuDownload(
                        imageURL,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target
                    )
                    return
                }

                // Fallback 2: simpler nearest-anchor lookup.
                self.findLinkAtPoint(point) { fallbackURL in
                    guard let fallbackURL else {
                        NSLog("CmuxWebView context download linked file: URL nil, using fallback action")
                        self.runContextMenuFallback(
                            action: fallback.action,
                            target: fallback.target,
                            sender: sender
                        )
                        return
                    }
                    let normalized = self.normalizedLinkedDownloadURL(fallbackURL)
                    guard self.isDownloadableScheme(normalized) else {
                        NSLog("CmuxWebView context download linked file: unsupported URL %@, using fallback action", fallbackURL.absoluteString)
                        self.runContextMenuFallback(
                            action: fallback.action,
                            target: fallback.target,
                            sender: sender
                        )
                        return
                    }
                    NSLog("CmuxWebView context download linked file fallback URL: %@ (normalized=%@)", fallbackURL.absoluteString, normalized.absoluteString)
                    self.startContextMenuDownload(
                        normalized,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target
                    )
                }
            }
        }
    }
}
