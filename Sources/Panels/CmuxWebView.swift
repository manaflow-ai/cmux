import AppKit
import Bonsplit
import ObjectiveC
import UniformTypeIdentifiers
import WebKit

/// WKWebView tends to consume some Command-key equivalents (e.g. Cmd+N/Cmd+W),
/// preventing the app menu/SwiftUI Commands from receiving them. Route menu
/// key equivalents first so app-level shortcuts continue to work when WebKit is
/// the first responder.
final class CmuxWebView: WKWebView {
    // Some sites/WebKit paths report middle-click link activations as
    // WKNavigationAction.buttonNumber=4 instead of 2. Track a recent local
    // middle-click so navigation delegates can recover intent reliably.
    private struct MiddleClickIntent {
        let webViewID: ObjectIdentifier
        let uptime: TimeInterval
    }

    private static var lastMiddleClickIntent: MiddleClickIntent?
    private static let middleClickIntentMaxAge: TimeInterval = 0.8

    static func hasRecentMiddleClickIntent(for webView: WKWebView) -> Bool {
        guard let webView = webView as? CmuxWebView else { return false }
        guard let intent = lastMiddleClickIntent else { return false }

        let age = ProcessInfo.processInfo.systemUptime - intent.uptime
        if age > middleClickIntentMaxAge {
            lastMiddleClickIntent = nil
            return false
        }

        return intent.webViewID == ObjectIdentifier(webView)
    }

    private static func recordMiddleClickIntent(for webView: CmuxWebView) {
        lastMiddleClickIntent = MiddleClickIntent(
            webViewID: ObjectIdentifier(webView),
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

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
        if event.keyCode == 36 || event.keyCode == 76 {
            // Always bypass app/menu key-equivalent routing for Return/Enter so WebKit
            // receives the keyDown path used by form submission handlers.
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Menu/app shortcut routing is only needed for Command equivalents
        // (New Tab, Close Tab, tab switching, split commands, etc).
        guard flags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
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

    // MARK: - Mouse back/forward buttons

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            Self.recordMiddleClickIntent(for: self)
        }
#if DEBUG
        let point = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        dlog(
            "browser.mouse.otherDown web=\(ObjectIdentifier(self)) button=\(event.buttonNumber) " +
            "clicks=\(event.clickCount) mods=\(mods) point=(\(Int(point.x)),\(Int(point.y)))"
        )
#endif
        // Button 3 = back, button 4 = forward (multi-button mice like Logitech).
        // Consume the event so WebKit doesn't handle it.
        switch event.buttonNumber {
        case 3:
#if DEBUG
            dlog("browser.mouse.otherDown.action web=\(ObjectIdentifier(self)) kind=goBack canGoBack=\(canGoBack ? 1 : 0)")
#endif
            goBack()
            return
        case 4:
#if DEBUG
            dlog("browser.mouse.otherDown.action web=\(ObjectIdentifier(self)) kind=goForward canGoForward=\(canGoForward ? 1 : 0)")
#endif
            goForward()
            return
        default:
            break
        }
        super.otherMouseDown(with: event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 {
            Self.recordMiddleClickIntent(for: self)
        }
#if DEBUG
        let point = convert(event.locationInWindow, from: nil)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        dlog(
            "browser.mouse.otherUp web=\(ObjectIdentifier(self)) button=\(event.buttonNumber) " +
            "clicks=\(event.clickCount) mods=\(mods) point=(\(Int(point.x)),\(Int(point.y)))"
        )
#endif
        super.otherMouseUp(with: event)
    }

    /// Finds the nearest anchor element at a given view-local point.
    /// Used as a context-menu download fallback.
    private func findLinkAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
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

    private static func makeContextDownloadTraceID(prefix: String) -> String {
#if DEBUG
        return "\(prefix)-\(UUID().uuidString.prefix(8))"
#else
        return prefix
#endif
    }

    private func debugContextDownload(_ message: @autoclosure () -> String) {
#if DEBUG
        dlog(message())
#endif
    }

    private static func selectorName(_ selector: Selector?) -> String {
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

    private struct ParsedDataURL {
        let data: Data
        let mimeType: String?
    }

    private static func parseDataURL(_ url: URL) -> ParsedDataURL? {
        let absolute = url.absoluteString
        guard absolute.hasPrefix("data:"),
              let commaIndex = absolute.firstIndex(of: ",") else {
            return nil
        }

        let headerStart = absolute.index(absolute.startIndex, offsetBy: 5)
        let header = String(absolute[headerStart..<commaIndex])
        let payloadStart = absolute.index(after: commaIndex)
        let payload = String(absolute[payloadStart...])

        let segments = header.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let mimeType = segments.first.flatMap { $0.isEmpty ? nil : $0 }
        let isBase64 = segments.dropFirst().contains { $0.caseInsensitiveCompare("base64") == .orderedSame }

        if isBase64 {
            guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
                return nil
            }
            return ParsedDataURL(data: data, mimeType: mimeType)
        }

        guard let decoded = payload.removingPercentEncoding else { return nil }
        return ParsedDataURL(data: Data(decoded.utf8), mimeType: mimeType)
    }

    private static func filenameExtension(forMIMEType mimeType: String?) -> String? {
        guard let mimeType, !mimeType.isEmpty else { return nil }
        if #available(macOS 11.0, *) {
            if let preferred = UTType(mimeType: mimeType)?.preferredFilenameExtension, !preferred.isEmpty {
                return preferred
            }
        }
        switch mimeType.lowercased() {
        case "image/jpeg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/webp":
            return "webp"
        case "image/gif":
            return "gif"
        case "text/html":
            return "html"
        case "text/plain":
            return "txt"
        default:
            return nil
        }
    }

    private static func suggestedFilenameForDataURL(
        mimeType: String?,
        suggestedFilename: String?
    ) -> String {
        if let suggested = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            return suggested
        }
        let ext = filenameExtension(forMIMEType: mimeType) ?? "bin"
        let base = (mimeType?.lowercased().hasPrefix("image/") ?? false) ? "image" : "download"
        return "\(base).\(ext)"
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

    private func isDownloadableScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    private func isDataURLScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return scheme == "data"
    }

    private func isDownloadSupportedScheme(_ url: URL) -> Bool {
        return isDownloadableScheme(url) || isDataURLScheme(url)
    }

    private func isOurDownloadMenuAction(target: AnyObject?, action: Selector?) -> Bool {
        guard target === self else { return false }
        return action == #selector(contextMenuDownloadImage(_:))
            || action == #selector(contextMenuDownloadLinkedFile(_:))
    }

    private func resolveGoogleRedirectURL(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(), host.contains("google.") else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
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

    private func isLikelyFaviconURL(_ url: URL) -> Bool {
        let lower = url.absoluteString.lowercased()
        if lower.contains("favicon") { return true }
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("favicon")
    }

    private func isLikelyImageURL(_ url: URL) -> Bool {
        if isDataURLScheme(url) {
            guard let parsed = Self.parseDataURL(url),
                  let mime = parsed.mimeType?.lowercased() else {
                return false
            }
            return mime.hasPrefix("image/")
        }
        guard isDownloadableScheme(url) else { return false }
        let ext = url.pathExtension.lowercased()
        if [
            "jpg", "jpeg", "png", "webp", "gif", "bmp",
            "svg", "avif", "heic", "heif", "tif", "tiff", "ico"
        ].contains(ext) {
            return true
        }
        let lower = url.absoluteString.lowercased()
        if lower.contains("imgurl=")
            || lower.contains("mediaurl=")
            || lower.contains("encrypted-tbn")
            || lower.contains("format=jpg")
            || lower.contains("format=jpeg")
            || lower.contains("format=png")
            || lower.contains("format=webp")
            || lower.contains("format=gif") {
            return true
        }
        return false
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
            const x = \(point.x);
            const y = \(flippedY);
            const normalize = (raw) => {
                if (!raw || typeof raw !== 'string') return '';
                const trimmed = raw.trim();
                if (!trimmed) return '';
                if (trimmed.startsWith('//')) return window.location.protocol + trimmed;
                return trimmed;
            };
            const firstSrcsetURL = (srcset) => {
                if (!srcset || typeof srcset !== 'string') return '';
                const first = srcset.split(',').map((part) => part.trim()).find(Boolean);
                if (!first) return '';
                const urlPart = first.split(/\\s+/)[0];
                return normalize(urlPart);
            };
            const firstBackgroundURL = (value) => {
                if (!value || value === 'none') return '';
                const match = /url\\((['"]?)(.*?)\\1\\)/.exec(value);
                if (!match || !match[2]) return '';
                return normalize(match[2]);
            };
            const collectChain = (start) => {
                const out = [];
                const seen = new Set();
                const pushParents = (node) => {
                    while (node && !seen.has(node)) {
                        seen.add(node);
                        out.push(node);
                        node = node.parentElement;
                    }
                };
                pushParents(start);
                if (start && start.tagName === 'PICTURE' && start.querySelector) {
                    const img = start.querySelector('img');
                    if (img) pushParents(img);
                }
                return out;
            };
            const candidateFromElement = (el) => {
                if (!el) return '';
                const attr = (name) => normalize(el.getAttribute ? el.getAttribute(name) : '');
                if (el.tagName === 'IMG') {
                    const imageCandidates = [
                        normalize(el.currentSrc || ''),
                        attr('src'),
                        firstSrcsetURL(attr('srcset')),
                        attr('data-src'),
                        attr('data-iurl'),
                        attr('data-lazy-src'),
                        attr('data-original'),
                    ];
                    const foundImage = imageCandidates.find(Boolean);
                    if (foundImage) return foundImage;
                }
                const genericAttrs = [
                    'src', 'data-src', 'data-iurl', 'data-lazy-src',
                    'data-original', 'data-image', 'data-image-url',
                    'data-thumb', 'data-thumbnail-url', 'content'
                ];
                for (const name of genericAttrs) {
                    const v = attr(name);
                    if (v) return v;
                }
                const inlineBg = firstBackgroundURL(el.style && el.style.backgroundImage ? el.style.backgroundImage : '');
                if (inlineBg) return inlineBg;
                try {
                    const computed = window.getComputedStyle(el);
                    const computedBg = firstBackgroundURL(computed ? computed.backgroundImage : '');
                    if (computedBg) return computedBg;
                } catch (_) {}
                if (el.querySelector) {
                    const nestedImg = el.querySelector('img[src],img[srcset],img[data-src],img[data-iurl],source[srcset]');
                    if (nestedImg) {
                        const nestedCandidates = [
                            normalize(nestedImg.currentSrc || ''),
                            normalize(nestedImg.getAttribute ? nestedImg.getAttribute('src') : ''),
                            firstSrcsetURL(nestedImg.getAttribute ? nestedImg.getAttribute('srcset') : ''),
                            normalize(nestedImg.getAttribute ? (nestedImg.getAttribute('data-src') || nestedImg.getAttribute('data-iurl') || '') : '')
                        ];
                        const foundNested = nestedCandidates.find(Boolean);
                        if (foundNested) return foundNested;
                    }
                    const nestedBg = el.querySelector('[style*="background-image"]');
                    if (nestedBg) {
                        const styleValue = nestedBg.getAttribute ? nestedBg.getAttribute('style') : '';
                        const bgURL = firstBackgroundURL(styleValue || '');
                        if (bgURL) return bgURL;
                    }
                }
                return '';
            };
            const tryNodes = (nodes) => {
                for (const start of nodes) {
                    for (const el of collectChain(start)) {
                        const found = candidateFromElement(el);
                        if (found) return found;
                    }
                    if (start && start.shadowRoot && start.shadowRoot.elementFromPoint) {
                        const inner = start.shadowRoot.elementFromPoint(x, y);
                        if (inner) {
                            for (const el of collectChain(inner)) {
                                const found = candidateFromElement(el);
                                if (found) return found;
                            }
                        }
                    }
                }
                return '';
            };
            const all = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
            const foundFromAll = tryNodes(all);
            if (foundFromAll) return foundFromAll;
            const single = document.elementFromPoint ? document.elementFromPoint(x, y) : null;
            return candidateFromElement(single) || '';
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
            const x = \(point.x);
            const y = \(flippedY);
            const normalize = (raw) => {
                if (!raw || typeof raw !== 'string') return '';
                const trimmed = raw.trim();
                if (!trimmed) return '';
                if (trimmed.startsWith('//')) return window.location.protocol + trimmed;
                return trimmed;
            };
            const collectChain = (start) => {
                const out = [];
                const seen = new Set();
                while (start && !seen.has(start)) {
                    seen.add(start);
                    out.push(start);
                    start = start.parentElement;
                }
                return out;
            };
            const linkFromElement = (el) => {
                if (!el) return '';
                const attr = (name) => normalize(el.getAttribute ? el.getAttribute(name) : '');
                if (el.closest) {
                    const closestLink = el.closest('a[href],area[href]');
                    if (closestLink && closestLink.href) return normalize(closestLink.href);
                }
                if ((el.tagName === 'A' || el.tagName === 'AREA') && el.href) {
                    return normalize(el.href);
                }
                const attrCandidates = ['href', 'data-href', 'data-url', 'data-link', 'data-link-url'];
                for (const name of attrCandidates) {
                    const v = attr(name);
                    if (v) return v;
                }
                if (el.querySelector) {
                    const nestedLink = el.querySelector('a[href],area[href]');
                    if (nestedLink && nestedLink.href) return normalize(nestedLink.href);
                }
                return '';
            };
            const tryNodes = (nodes) => {
                for (const start of nodes) {
                    for (const node of collectChain(start)) {
                        const found = linkFromElement(node);
                        if (found) return found;
                    }
                    if (start && start.shadowRoot && start.shadowRoot.elementFromPoint) {
                        const inner = start.shadowRoot.elementFromPoint(x, y);
                        if (inner) {
                            for (const node of collectChain(inner)) {
                                const found = linkFromElement(node);
                                if (found) return found;
                            }
                        }
                    }
                }
                return '';
            };
            const nodes = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
            const found = tryNodes(nodes);
            if (found) return found;
            const single = document.elementFromPoint ? document.elementFromPoint(x, y) : null;
            return linkFromElement(single) || '';
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

    private func debugInspectElementsAtPoint(_ point: NSPoint, traceID: String, kind: String) {
#if DEBUG
        let flippedY = bounds.height - point.y
        let js = """
        (() => {
            const clip = (value, max = 180) => {
                if (value == null) return '';
                const s = String(value);
                return s.length > max ? s.slice(0, max) + '…' : s;
            };
            const x = \(point.x);
            const y = \(flippedY);
            const nodes = document.elementsFromPoint ? document.elementsFromPoint(x, y) : [];
            const entries = [];
            const limit = Math.min(nodes.length, 8);
            for (let i = 0; i < limit; i++) {
                const el = nodes[i];
                if (!el) continue;
                entries.push({
                    tag: clip((el.tagName || '').toLowerCase()),
                    id: clip(el.id || ''),
                    cls: clip(typeof el.className === 'string' ? el.className : ''),
                    href: clip(el.href || ''),
                    src: clip(el.src || ''),
                    currentSrc: clip(el.currentSrc || ''),
                    dataHref: clip(el.getAttribute ? el.getAttribute('data-href') : ''),
                    dataSrc: clip(el.getAttribute ? el.getAttribute('data-src') : '')
                });
            }
            return JSON.stringify({count: nodes.length, entries});
        })();
        """
        evaluateJavaScript(js) { [weak self] result, _ in
            guard let self,
                  let payload = result as? String,
                  !payload.isEmpty else { return }
            self.debugContextDownload(
                "browser.ctxdl.inspect trace=\(traceID) kind=\(kind) payload=\(payload)"
            )
        }
#endif
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

    private func runContextMenuFallback(
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
        if target === self,
           action == #selector(contextMenuDownloadImage(_:))
            || action == #selector(contextMenuDownloadLinkedFile(_:)) {
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
        fallbackTarget: AnyObject?,
        traceID: String
    ) {
        guard isDownloadSupportedScheme(url) else {
            debugContextDownload(
                "browser.ctxdl.request trace=\(traceID) stage=rejectUnsupportedScheme url=\(url.absoluteString)"
            )
            runContextMenuFallback(
                action: fallbackAction,
                target: fallbackTarget,
                sender: sender,
                traceID: traceID,
                reason: "unsupported_scheme"
            )
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        debugContextDownload(
            "browser.ctxdl.request trace=\(traceID) stage=start scheme=\(scheme) url=\(url.absoluteString)"
        )
        notifyContextMenuDownloadState(true)
        debugContextDownload("browser.ctxdl.state trace=\(traceID) downloading=1")

        if scheme == "data" {
            DispatchQueue.main.async {
                guard let parsed = Self.parseDataURL(url) else {
                    self.notifyContextMenuDownloadState(false)
                    self.debugContextDownload(
                        "browser.ctxdl.data trace=\(traceID) stage=parseFailure urlLength=\(url.absoluteString.count)"
                    )
                    self.runContextMenuFallback(
                        action: fallbackAction,
                        target: fallbackTarget,
                        sender: sender,
                        traceID: traceID,
                        reason: "data_url_parse_error"
                    )
                    return
                }

                let saveName = Self.suggestedFilenameForDataURL(
                    mimeType: parsed.mimeType,
                    suggestedFilename: suggestedFilename
                )
                self.debugContextDownload(
                    "browser.ctxdl.data trace=\(traceID) stage=parseSuccess mime=\(parsed.mimeType ?? "nil") bytes=\(parsed.data.count)"
                )

                let savePanel = NSSavePanel()
                savePanel.nameFieldStringValue = saveName
                savePanel.canCreateDirectories = true
                savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                self.notifyContextMenuDownloadState(false)
                self.debugContextDownload(
                    "browser.ctxdl.data trace=\(traceID) stage=savePrompt shown=1 defaultName=\(saveName)"
                )
                savePanel.begin { result in
                    guard result == .OK, let destURL = savePanel.url else {
                        self.debugContextDownload(
                            "browser.ctxdl.data trace=\(traceID) stage=savePrompt result=cancel"
                        )
                        return
                    }
                    do {
                        try parsed.data.write(to: destURL, options: .atomic)
                        self.debugContextDownload(
                            "browser.ctxdl.data trace=\(traceID) stage=saveSuccess path=\(destURL.path)"
                        )
                    } catch {
                        self.debugContextDownload(
                            "browser.ctxdl.data trace=\(traceID) stage=saveFailure error=\(error.localizedDescription)"
                        )
                        self.runContextMenuFallback(
                            action: fallbackAction,
                            target: fallbackTarget,
                            sender: sender,
                            traceID: traceID,
                            reason: "data_save_write_error"
                        )
                    }
                }
            }
            return
        }

        if scheme == "file" {
            DispatchQueue.main.async {
                do {
                    let data = try Data(contentsOf: url)
                    self.debugContextDownload(
                        "browser.ctxdl.file trace=\(traceID) stage=readSuccess bytes=\(data.count) path=\(url.path)"
                    )
                    let filename = suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let saveName = (filename?.isEmpty == false ? filename! : url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent)
                    let savePanel = NSSavePanel()
                    savePanel.nameFieldStringValue = saveName
                    savePanel.canCreateDirectories = true
                    savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                    // Download is already complete; we're now waiting for user save choice.
                    self.notifyContextMenuDownloadState(false)
                    self.debugContextDownload(
                        "browser.ctxdl.file trace=\(traceID) stage=savePrompt shown=1 defaultName=\(saveName)"
                    )
                    savePanel.begin { result in
                        guard result == .OK, let destURL = savePanel.url else {
                            self.debugContextDownload(
                                "browser.ctxdl.file trace=\(traceID) stage=savePrompt result=cancel"
                            )
                            return
                        }
                        do {
                            try data.write(to: destURL, options: .atomic)
                            self.debugContextDownload(
                                "browser.ctxdl.file trace=\(traceID) stage=saveSuccess path=\(destURL.path)"
                            )
                        } catch {
                            self.debugContextDownload(
                                "browser.ctxdl.file trace=\(traceID) stage=saveFailure error=\(error.localizedDescription)"
                            )
                        }
                    }
                } catch {
                    self.notifyContextMenuDownloadState(false)
                    self.debugContextDownload(
                        "browser.ctxdl.file trace=\(traceID) stage=readFailure error=\(error.localizedDescription)"
                    )
                    self.runContextMenuFallback(
                        action: fallbackAction,
                        target: fallbackTarget,
                        sender: sender,
                        traceID: traceID,
                        reason: "file_read_error"
                    )
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
            self.debugContextDownload(
                "browser.ctxdl.request trace=\(traceID) stage=dispatch method=\(request.httpMethod ?? "GET") cookies=\(cookies.count) referer=\(request.value(forHTTPHeaderField: "Referer") ?? "nil") uaSet=\(request.value(forHTTPHeaderField: "User-Agent") == nil ? 0 : 1)"
            )

            URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    guard let data, error == nil else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                        let mime = response?.mimeType ?? "nil"
                        let hasResponse = response == nil ? 0 : 1
                        self.debugContextDownload(
                            "browser.ctxdl.response trace=\(traceID) stage=failure hasResponse=\(hasResponse) status=\(statusCode) mime=\(mime) error=\(error?.localizedDescription ?? "unknown")"
                        )
                        self.notifyContextMenuDownloadState(false)
                        self.runContextMenuFallback(
                            action: fallbackAction,
                            target: fallbackTarget,
                            sender: sender,
                            traceID: traceID,
                            reason: "network_error"
                        )
                        return
                    }
                    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                    let mime = response?.mimeType ?? "nil"
                    let expectedLength = response?.expectedContentLength ?? -1
                    self.debugContextDownload(
                        "browser.ctxdl.response trace=\(traceID) stage=success hasResponse=1 status=\(statusCode) mime=\(mime) bytes=\(data.count) expected=\(expectedLength)"
                    )
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
                    self.debugContextDownload(
                        "browser.ctxdl.response trace=\(traceID) stage=savePrompt shown=1 defaultName=\(saveName)"
                    )
                    savePanel.begin { result in
                        guard result == .OK, let destURL = savePanel.url else {
                            self.debugContextDownload(
                                "browser.ctxdl.response trace=\(traceID) stage=savePrompt result=cancel"
                            )
                            return
                        }
                        do {
                            try data.write(to: destURL, options: .atomic)
                            self.debugContextDownload(
                                "browser.ctxdl.response trace=\(traceID) stage=saveSuccess path=\(destURL.path)"
                            )
                        } catch {
                            self.debugContextDownload(
                                "browser.ctxdl.response trace=\(traceID) stage=saveFailure error=\(error.localizedDescription)"
                            )
                            self.runContextMenuFallback(
                                action: fallbackAction,
                                target: fallbackTarget,
                                sender: sender,
                                traceID: traceID,
                                reason: "save_write_error"
                            )
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
        fallbackTarget: AnyObject?,
        traceID: String
    ) {
        debugContextDownload("browser.ctxdl.start trace=\(traceID) url=\(url.absoluteString)")
        downloadURLViaSession(
            url,
            suggestedFilename: nil,
            sender: sender,
            fallbackAction: fallbackAction,
            fallbackTarget: fallbackTarget,
            traceID: traceID
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
        debugContextDownload(
            "browser.ctxdl.menu open itemCount=\(menu.items.count) point=(\(Int(lastContextMenuPoint.x)),\(Int(lastContextMenuPoint.y)))"
        )
        var openLinkInsertionIndex: Int?
        var hasDefaultBrowserOpenLinkItem = false

        for (index, item) in menu.items.enumerated() {
            debugLogContextMenuDownloadCandidate(item, index: index)
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

            if isDownloadImageMenuItem(item) {
                debugContextDownload(
                    "browser.ctxdl.menu hook kind=image index=\(index) id=\(item.identifier?.rawValue ?? "nil") title=\(item.title) action=\(Self.selectorName(item.action))"
                )
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

            if isDownloadLinkedFileMenuItem(item) {
                debugContextDownload(
                    "browser.ctxdl.menu hook kind=linked index=\(index) id=\(item.identifier?.rawValue ?? "nil") title=\(item.title) action=\(Self.selectorName(item.action))"
                )
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
        let traceID = Self.makeContextDownloadTraceID(prefix: "img")
        let point = lastContextMenuPoint
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) kind=image point=(\(Int(point.x)),\(Int(point.y)))"
        )
        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackDownloadImageAction,
            defaultTarget: fallbackDownloadImageTarget
        )
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) fallback action=\(Self.selectorName(fallback.action)) target=\(String(describing: fallback.target))"
        )
        findImageURLAtPoint(point) { [weak self] url in
            guard let self else { return }
            self.debugContextDownload(
                "browser.ctxdl.resolve trace=\(traceID) kind=image imageURL=\(url?.absoluteString ?? "nil")"
            )
            var dataImageURL: URL?
            var weakImageURL: URL?
            if let url {
                let scheme = url.scheme?.lowercased() ?? ""
                if scheme == "data" {
                    dataImageURL = url
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image dataURLDetected length=\(url.absoluteString.count)"
                    )
                } else if scheme == "http" || scheme == "https" || scheme == "file" {
                    let normalized = self.normalizedLinkedDownloadURL(url)
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedImageURL=\(normalized.absoluteString)"
                    )
                    if self.isLikelyImageURL(normalized) {
                        if !self.isLikelyFaviconURL(normalized) {
                            self.startContextMenuDownload(
                                normalized,
                                sender: sender,
                                fallbackAction: fallback.action,
                                fallbackTarget: fallback.target,
                                traceID: traceID
                            )
                            return
                        }
                        weakImageURL = normalized
                        self.debugContextDownload(
                            "browser.ctxdl.resolve trace=\(traceID) kind=image weakCandidateURL=\(normalized.absoluteString) reason=favicon_or_low_confidence"
                        )
                    } else if self.isDownloadableScheme(normalized), !self.isLikelyFaviconURL(normalized) {
                        // Some image CDNs use extensionless URLs; keep as last-resort candidate.
                        weakImageURL = normalized
                        self.debugContextDownload(
                            "browser.ctxdl.resolve trace=\(traceID) kind=image weakCandidateURL=\(normalized.absoluteString) reason=unclassified_direct_image_src"
                        )
                    }
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image rejectedPrimaryImageURL=\(normalized.absoluteString)"
                    )
                }
            }

            // Google Images and similar sites often expose blob:/data: image URLs.
            // If image URL is not directly downloadable, fall back to the nearby link URL.
            self.findLinkURLAtPoint(point) { linkURL in
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackLinkURL=\(linkURL?.absoluteString ?? "nil")"
                )
                if let linkURL {
                    let normalizedLink = self.normalizedLinkedDownloadURL(linkURL)
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image normalizedFallbackLinkURL=\(normalizedLink.absoluteString)"
                    )
                    if self.isDownloadableScheme(normalizedLink),
                       self.isLikelyImageURL(normalizedLink),
                       !self.isLikelyFaviconURL(normalizedLink) {
                        self.startContextMenuDownload(
                            normalizedLink,
                            sender: sender,
                            fallbackAction: fallback.action,
                            fallbackTarget: fallback.target,
                            traceID: traceID
                        )
                        return
                    }
                }

                if let dataImageURL {
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackToDataURL=1"
                    )
                    self.startContextMenuDownload(
                        dataImageURL,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                    return
                }

                if let weakImageURL {
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=image fallbackToWeakCandidate=1"
                    )
                    self.startContextMenuDownload(
                        weakImageURL,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                    return
                }

                if let linkURL {
                    self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "image")
                    self.runContextMenuFallback(
                        action: fallback.action,
                        target: fallback.target,
                        sender: sender,
                        traceID: traceID,
                        reason: "fallback_link_not_image"
                    )
                    return
                }

                self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "image")
                self.runContextMenuFallback(
                    action: fallback.action,
                    target: fallback.target,
                    sender: sender,
                    traceID: traceID,
                    reason: "no_image_or_link_url"
                )
            }
        }
    }

    @objc private func contextMenuDownloadLinkedFile(_ sender: Any?) {
        let traceID = Self.makeContextDownloadTraceID(prefix: "lnk")
        let point = lastContextMenuPoint
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) kind=linked point=(\(Int(point.x)),\(Int(point.y)))"
        )
        let fallback = fallbackFromSender(
            sender,
            defaultAction: fallbackDownloadLinkedFileAction,
            defaultTarget: fallbackDownloadLinkedFileTarget
        )
        debugContextDownload(
            "browser.ctxdl.click trace=\(traceID) fallback action=\(Self.selectorName(fallback.action)) target=\(String(describing: fallback.target))"
        )
        findLinkURLAtPoint(point) { [weak self] url in
            guard let self else { return }
            self.debugContextDownload(
                "browser.ctxdl.resolve trace=\(traceID) kind=linked linkURL=\(url?.absoluteString ?? "nil")"
            )
            if let url {
                let normalized = self.normalizedLinkedDownloadURL(url)
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=linked normalizedLinkURL=\(normalized.absoluteString)"
                )
                if self.isDownloadSupportedScheme(normalized) {
                    self.startContextMenuDownload(
                        normalized,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                    return
                }
            }

            // Fallback 1: image URL under cursor (useful on image-heavy result pages).
            self.findImageURLAtPoint(point) { imageURL in
                self.debugContextDownload(
                    "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackImageURL=\(imageURL?.absoluteString ?? "nil")"
                )
                var dataImageURL: URL?
                if let imageURL, self.isDownloadableScheme(imageURL) {
                    self.startContextMenuDownload(
                        imageURL,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                    return
                }
                if let imageURL, self.isDataURLScheme(imageURL) {
                    dataImageURL = imageURL
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackDataURLDetected length=\(imageURL.absoluteString.count)"
                    )
                }

                // Fallback 2: simpler nearest-anchor lookup.
                self.findLinkAtPoint(point) { fallbackURL in
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked nearestAnchorURL=\(fallbackURL?.absoluteString ?? "nil")"
                    )
                    guard let fallbackURL else {
                        if let dataImageURL {
                            self.debugContextDownload(
                                "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackToDataURL=1"
                            )
                            self.startContextMenuDownload(
                                dataImageURL,
                                sender: sender,
                                fallbackAction: fallback.action,
                                fallbackTarget: fallback.target,
                                traceID: traceID
                            )
                            return
                        }
                        self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "linked")
                        self.runContextMenuFallback(
                            action: fallback.action,
                            target: fallback.target,
                            sender: sender,
                            traceID: traceID,
                            reason: "no_link_or_image_url"
                        )
                        return
                    }
                    let normalized = self.normalizedLinkedDownloadURL(fallbackURL)
                    self.debugContextDownload(
                        "browser.ctxdl.resolve trace=\(traceID) kind=linked normalizedNearestAnchorURL=\(normalized.absoluteString)"
                    )
                    guard self.isDownloadSupportedScheme(normalized) else {
                        if let dataImageURL {
                            self.debugContextDownload(
                                "browser.ctxdl.resolve trace=\(traceID) kind=linked fallbackToDataURL=1"
                            )
                            self.startContextMenuDownload(
                                dataImageURL,
                                sender: sender,
                                fallbackAction: fallback.action,
                                fallbackTarget: fallback.target,
                                traceID: traceID
                            )
                            return
                        }
                        self.debugInspectElementsAtPoint(point, traceID: traceID, kind: "linked")
                        self.runContextMenuFallback(
                            action: fallback.action,
                            target: fallback.target,
                            sender: sender,
                            traceID: traceID,
                            reason: "nearest_anchor_unsupported_scheme"
                        )
                        return
                    }
                    self.startContextMenuDownload(
                        normalized,
                        sender: sender,
                        fallbackAction: fallback.action,
                        fallbackTarget: fallback.target,
                        traceID: traceID
                    )
                }
            }
        }
    }
}
