#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextCompat
public import CmuxNextPages
public import WebKit

/// `debug.agent_pane click` and `hover` (DEBUG builds), in whichever engine the page host shows
/// the chat: these read and press the page the chat shows.
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
                  let object = (try? JSONSerialization.blockingJSONObject(with: Data(json.utf8))) as? [String: Any] else {
                return ["error": "the page returned no JSON"]
            }
            return object
        } catch {
            return ["error": String(describing: error)]
        }
    }

    /// Whether the chat shows in Chromium (its clicks go through the page, ``debugPress(x:y:)``).
    public var debugShowsChromium: Bool { page.showsChromium }

    /// The zoom the chat shows at: view points per page CSS pixel, in either engine.
    public var debugPageZoom: Double { page.pageZoom }

    /// The WebKit view that shows the chat, which AppKit clicks go to; nil when the chat shows in
    /// Chromium.
    public var debugPageWebView: WKWebView? { page.webKitEngine }

    /// A trusted left click at `x`,`y` (CSS pixels) on a chat shown in Chromium: the engine's native
    /// click, DevTools input on an older fork (``PageWebView/debugPress(x:y:)``).
    ///
    /// - Returns: The path that delivered the click; nil when the chat is not in Chromium or DevTools refused it.
    public func debugPress(x: Double, y: Double) async -> PageDebugInputPath? {
        await page.debugPress(x: x, y: y)
    }
}
#endif
