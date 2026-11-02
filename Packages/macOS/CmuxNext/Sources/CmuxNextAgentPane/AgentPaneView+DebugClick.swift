#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextPages
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

    /// Whether the chat is to show in Chromium but Chromium has not attached yet: the page shows
    /// nothing until it does, or until it falls back to WebKit.
    public var debugChromiumStarting: Bool { pageDrawsOverCovers && !debugShowsChromium }

    /// Whether the document has painted, independently of the loading cover's give-up deadline.
    public var debugPageHasPainted: Bool { model.hasPainted && (page?.hasPainted ?? true) }

    /// Whether the chat's Chromium page is one a window snapshot draws: in this window, not parked,
    /// hidden or under a clear (alpha 0) ancestor, and with a size.
    public var debugChromiumPageShown: Bool {
        guard let page, let window = page.window else { return false }
        return PageRegistry.shownChromiumPages(in: window).contains { $0.page === page }
    }

    /// The paint and engine state a scene capture must wait for before drawing the agent pane.
    public var debugCaptureState: AgentPaneCaptureState {
        AgentPaneCaptureState(attached: webView.window != nil, loading: webView.isLoading,
                              chromium: debugShowsChromium, chromiumStarting: debugChromiumStarting,
                              chromiumShown: debugChromiumPageShown, painted: debugPageHasPainted)
    }

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

    /// The chat's file input `selector` takes the files at `paths`, as a pick in Chromium's open panel
    /// (``PageWebView/debugSetFiles(selector:paths:)``); nil when it did, else why not. On WebKit the next
    /// file input the page opens (a click on + then Attach files) takes them instead of the panel.
    public func debugSetFiles(selector: String, paths: [String]) async -> String? {
        if let page, page.showsChromium { return await page.debugSetFiles(selector: selector, paths: paths) }
        let files = paths.map { URL(fileURLWithPath: $0) }
        fileChooser?.debugAnswer = files
        page?.debugQueueFiles(files)
        return nil
    }

    /// The screen point of `x`,`y` (CSS pixels) on the chat's Chromium page, nil on WebKit. Chromium draws the
    /// page in its own child window over ``chromiumPage``'s container view (which stays in the pane's window):
    /// `debug.agent_pane click` turns the point into that window's mouse down for ``judge(_:eventWindow:)``,
    /// the host's half of a person's click there. The DevTools press (``debugPress(x:y:)``) is the page's half
    /// and is never seen by the gesture monitor, so without it a click on a Chromium chat records no gesture and
    /// the answer it picks is refused (`transport.gesture_required`).
    public func debugChromiumScreenPoint(x: Double, y: Double) -> NSPoint? {
        guard let content = chromiumPage?.contentView, let window = content.window else { return nil }
        let zoom = max(debugPageZoom, 0.01)
        let local = NSPoint(x: x * zoom, y: content.isFlipped ? y * zoom : content.bounds.height - y * zoom)
        return window.convertPoint(toScreen: content.convert(local, to: nil))
    }
}
#endif
