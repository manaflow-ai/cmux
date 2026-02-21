import AppKit
import WebKit

/// WKWebView tends to consume some Command-key equivalents (e.g. Cmd+N/Cmd+W),
/// preventing the app menu/SwiftUI Commands from receiving them. Route menu
/// key equivalents first so app-level shortcuts continue to work when WebKit is
/// the first responder.
final class CmuxWebView: WKWebView {
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
        NotificationCenter.default.post(name: .webViewDidReceiveClick, object: self)
        super.mouseDown(with: event)
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

    // MARK: - Context menu download point

    /// The last right-click point (in view coordinates) for context menu downloads.
    private var lastContextMenuPoint: NSPoint = .zero

    override func rightMouseDown(with event: NSEvent) {
        lastContextMenuPoint = convert(event.locationInWindow, from: nil)
        super.rightMouseDown(with: event)
    }

    /// Use JavaScript to find the image src at the given view-local point.
    private func findImageURLAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
        let flippedY = bounds.height - point.y
        let js = """
        (() => {
            let el = document.elementFromPoint(\(point.x), \(flippedY));
            while (el) {
                if (el.tagName === 'IMG' && el.src) return el.src;
                if (el.tagName === 'PICTURE') {
                    const img = el.querySelector('img');
                    if (img && img.src) return img.src;
                }
                el = el.parentElement;
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

    /// Use JavaScript to find the link href at the given view-local point.
    private func findLinkURLAtPoint(_ point: NSPoint, completion: @escaping (URL?) -> Void) {
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

    /// Download a URL to disk: fetch data first (with forwarded WKWebView cookies),
    /// then show NSSavePanel once the data is ready.
    private func downloadURL(_ url: URL, suggestedFilename: String?) {
        NSLog("CmuxWebView download: %@", url.absoluteString)

        // Forward cookies from WKWebView so authenticated downloads work.
        let cookieStore = configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            var request = URLRequest(url: url)
            let cookieHeaders = HTTPCookie.requestHeaderFields(with: cookies)
            for (key, value) in cookieHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }

            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                DispatchQueue.main.async {
                    guard let data, error == nil else {
                        NSLog("CmuxWebView download failed: %@", error?.localizedDescription ?? "unknown")
                        return
                    }
                    let filename = suggestedFilename
                        ?? response?.suggestedFilename
                        ?? url.lastPathComponent

                    let savePanel = NSSavePanel()
                    savePanel.nameFieldStringValue = filename
                    savePanel.canCreateDirectories = true
                    savePanel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

                    savePanel.begin { result in
                        guard result == .OK, let destURL = savePanel.url else { return }
                        do {
                            try data.write(to: destURL, options: .atomic)
                            NSLog("CmuxWebView download saved: %@", destURL.path)
                        } catch {
                            NSLog("CmuxWebView download save failed: %@", error.localizedDescription)
                        }
                    }
                }
            }
            task.resume()
        }
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

        for item in menu.items {
            // Rename "Open Link in New Window" to "Open Link in New Tab".
            // The UIDelegate's createWebViewWith already handles the action
            // by opening the link as a new surface in the same pane.
            if item.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow"
                || item.title.contains("Open Link in New Window") {
                item.title = "Open Link in New Tab"
            }

            // Intercept "Download Image" — WebKit's built-in handler silently fails
            // because WKWebView doesn't expose the private contextMenuDidCreateDownload
            // callback. Replace with our own URLSession-based download.
            if item.identifier?.rawValue == "WKMenuItemIdentifierDownloadImage"
                || item.title == "Download Image" {
                item.target = self
                item.action = #selector(contextMenuDownloadImage(_:))
            }

            // Intercept "Download Linked File" for the same reason.
            if item.identifier?.rawValue == "WKMenuItemIdentifierDownloadLinkedFile"
                || item.title == "Download Linked File" {
                item.target = self
                item.action = #selector(contextMenuDownloadLinkedFile(_:))
            }
        }
    }

    @objc private func contextMenuDownloadImage(_ sender: Any?) {
        findImageURLAtPoint(lastContextMenuPoint) { [weak self] url in
            guard let self, let url else {
                return
            }
            self.downloadURL(url, suggestedFilename: nil)
        }
    }

    @objc private func contextMenuDownloadLinkedFile(_ sender: Any?) {
        findLinkURLAtPoint(lastContextMenuPoint) { [weak self] url in
            guard let self, let url else {
                return
            }
            self.downloadURL(url, suggestedFilename: nil)
        }
    }
}
