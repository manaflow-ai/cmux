#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
public import WebKit

/// `debug.agent_pane click` and `hover` (DEBUG builds), on whichever host shows the chat: the
/// pane's own WebKit view, or the shared page host (`agent.pageHost`) in WebKit or Chromium. The
/// pane's own `webView` holds no document on the page host, so these read and press the page the
/// chat shows.
extension AgentPaneView {
    /// Finds the element, scrolls it into view and returns its center in CSS pixels.
    private static let locateScript = """
        const visible = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
        let target = null;
        if (selector) {
            target = [...document.querySelectorAll(selector)].find(visible) ?? null;
        } else {
            const want = text.trim();
            let area = Infinity;
            for (const el of document.querySelectorAll('body *')) {
                if (!(el instanceof HTMLElement) || !visible(el)) continue;
                const label = (el.innerText || el.getAttribute('aria-label') || '').trim();
                if (label !== want) continue;
                const r = el.getBoundingClientRect();
                if (r.width * r.height < area) { area = r.width * r.height; target = el; }
            }
        }
        if (!target) return JSON.stringify({ error: 'no visible element matches' });
        // What the page sees of the click (`page_events` in the result).
        const seen = [];
        window.__cmuxDebugClick = seen;
        for (const type of ['pointerdown', 'mousedown', 'mouseup', 'click']) {
            window.addEventListener(type, function note(e) {
                if (window.__cmuxDebugClick !== seen) return window.removeEventListener(type, note, true);
                seen.push(type + (e.isTrusted ? '' : '?'));
            }, true);
        }
        target.scrollIntoView({ block: 'nearest', inline: 'nearest' });
        const r = target.getBoundingClientRect();
        return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2, tag: target.tagName.toLowerCase() });
        """

    /// The element of the chat's page matching `selector` (CSS), or by `text` (its visible text or
    /// accessible name; the smallest element that matches): `{x, y, tag}` in CSS pixels, or `{error}`.
    public func debugLocate(selector: String, text: String) async -> [String: Any] {
        do {
            let result = try await callPageScript(Self.locateScript, arguments: ["selector": selector, "text": text])
            guard let json = result as? String,
                  let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                return ["error": "the page returned no JSON"]
            }
            return object
        } catch {
            return ["error": String(describing: error)]
        }
    }

    /// Whether the chat shows in Chromium (its clicks go through DevTools, ``debugPress(x:y:)``).
    public var debugShowsChromium: Bool { page?.showsChromium == true }

    /// The zoom the chat shows at: view points per page CSS pixel.
    public var debugPageZoom: Double {
        guard let page else { return webView.pageZoom * webView.magnification }
        return page.showsChromium ? page.debugPageZoom : page.webKitView.pageZoom * page.webKitView.magnification
    }

    /// The WebKit view that shows the chat (the page host's or the pane's own), which AppKit
    /// clicks go to; nil when the chat shows in Chromium.
    public var debugPageWebView: WKWebView? {
        guard let page else { return webView }
        return page.showsChromium ? nil : page.webKitView
    }

    /// A trusted DevTools left click at `x`,`y` (CSS pixels) on a chat shown in Chromium; false
    /// otherwise (``PageWebView/debugPress(x:y:)``).
    public func debugPress(x: Double, y: Double) async -> Bool {
        await page?.debugPress(x: x, y: y) ?? false
    }

    /// The window the chat's Chromium page draws in (a child of the pane's window); nil on WebKit.
    /// `debug.key {target: page}` delivers its key there, and the pane's gesture monitor judges it.
    public var debugChromiumPageWindow: NSWindow? { chromiumPage?.contentView.window }

    /// A left mouse down at `x`,`y` (CSS pixels) on the chat's Chromium page, through the pane's
    /// gesture monitor only: the host's half of a person's click there, which a real click passes
    /// before Chromium gets it. The DevTools press (``debugPress(x:y:)``) is the page's half and is
    /// never seen by the monitor, so without this a click on a Chromium chat records no gesture and
    /// the answer it picks is refused (`transport.gesture_required`). The gesture rule is the
    /// person rule of a real click (``judge(_:eventWindow:)``); false when the page has no window.
    @discardableResult
    public func debugJudgeChromiumClick(x: Double, y: Double) -> Bool {
        guard let content = chromiumPage?.contentView, let window = content.window else { return false }
        let zoom = max(debugPageZoom, 0.01)
        let local = NSPoint(x: x * zoom, y: content.isFlipped ? y * zoom : content.bounds.height - y * zoom)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: content.convert(local, to: nil), modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
        judge(down, eventWindow: window)
        return true
    }
}
#endif
