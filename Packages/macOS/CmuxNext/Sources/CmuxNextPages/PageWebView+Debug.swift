#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings
import CmuxNextDesign
public import Foundation
import AppKit
import ObjectiveC
public import WebKit

/// The generic page debug verb (`debug.page {page, state | snapshot}`): what any page shows, read
/// from the DOM, and the page as WebKit rendered it. Absorbed from the Settings lead's
/// `debug.settings_web` (branch feat-cmux-next-settings-react).
extension PageWebView {
    /// URL fragment, visible text (first 400 characters), control count, the computed html and
    /// body backgrounds (the one-backdrop check), the focused element with its value (typing
    /// checks) and `<html>`'s `data-*` attributes (pages publish their own probes there, such as the
    /// diff page's highlight worker counters).
    public func debugState() async -> JSONValue {
        let script = """
        return JSON.stringify({
          page: document.documentElement.dataset.cmuxPage || null,
          hash: location.hash,
          lang: document.documentElement.lang,
          text: (document.body && document.body.innerText || '').slice(0, 400),
          controls: document.querySelectorAll('input,select,button,[role=switch],[role=radio],[role=option]').length,
          html: getComputedStyle(document.documentElement).backgroundColor,
          body: document.body ? getComputedStyle(document.body).backgroundColor : null,
          painted_ms: document.documentElement.dataset.cmuxPainted ? Number(document.documentElement.dataset.cmuxPainted) : null,
          device_pixel_ratio: window.devicePixelRatio,
          active: document.activeElement && document.activeElement !== document.body
            ? { tag: document.activeElement.tagName.toLowerCase(), value: 'value' in document.activeElement ? String(document.activeElement.value) : null }
            : null,
          data: Object.assign({}, document.documentElement.dataset)
        });
        """
        // Whether a first click in an inactive window reaches this page (the view's own answer).
        let firstMouse = JSONValue.bool(webView.acceptsFirstMouse(for: nil))
        guard let text = await callPageFunction(script) as? String,
              case .object(var members)? = try? JSONValue.parse(Data(text.utf8)) else {
            return ["error": "page not loaded", "accepts_first_mouse": firstMouse]
        }
        members["accepts_first_mouse"] = firstMouse
        // Which engine shows the page, and why when it is WebKit (``PageEnginePolicy``).
        members["engine"] = .string(chromiumSession != nil ? "chromium" : "webkit")
        members["webkit_reason"] = chromiumSession != nil ? .null : engineDecision.webKitReason.map { .string($0.rawValue) } ?? .null
        return .object(members)
    }

    /// SCROLLBARS-THIN audit: the page's `data-scrollers` and every element that would show
    /// a scroller at rest under "Always" (its overflow is auto or scroll on an axis whose content is
    /// larger than its box), with the overflow in CSS pixels. An overflow of a few pixels is a
    /// layout bug that "Always" makes visible.
    public func debugScrollers() async -> JSONValue {
        let script = """
        const out = [];
        const name = (el) => {
          let s = el.tagName.toLowerCase();
          if (el.id) s += '#' + el.id;
          const cls = typeof el.className === 'string' ? el.className.trim().split(/\\s+/).slice(0, 3).join('.') : '';
          if (cls) s += '.' + cls;
          return s;
        };
        const path = (el) => {
          const parts = [];
          for (let e = el; e && e.nodeType === 1 && parts.length < 4; e = e.parentElement) parts.unshift(name(e));
          return parts.join(' > ');
        };
        const scrolls = (v) => v === 'auto' || v === 'scroll' || v === 'overlay';
        const visit = (root) => {
          for (const el of root.querySelectorAll('*')) {
            if (el.shadowRoot) visit(el.shadowRoot);
            const cs = getComputedStyle(el);
            if (cs.display === 'none' || cs.visibility === 'hidden') continue;
            const isRoot = el === document.scrollingElement;
            const y = el.scrollHeight - el.clientHeight;
            const x = el.scrollWidth - el.clientWidth;
            const rootY = isRoot && cs.overflowY !== 'hidden' && getComputedStyle(document.body || el).overflowY !== 'hidden';
            const rootX = isRoot && cs.overflowX !== 'hidden' && getComputedStyle(document.body || el).overflowX !== 'hidden';
            if (y > 0 && (scrolls(cs.overflowY) || rootY)) out.push({ element: path(el), axis: 'y', overflow: y, box: el.clientHeight });
            if (x > 0 && (scrolls(cs.overflowX) || rootX)) out.push({ element: path(el), axis: 'x', overflow: x, box: el.clientWidth });
          }
        };
        visit(document);
        return JSON.stringify({ scrollers: document.documentElement.getAttribute('data-scrollers'), overflowing: out });
        """
        guard let text = await callPageFunction(script) as? String,
              let value = try? JSONValue.parse(Data(text.utf8)) else { return ["error": "page not loaded"] }
        return value
    }

    /// Clicks the first element that matches the CSS `selector` (live GUI proofs drive a page
    /// control with no pointer). Returns whether an element matched.
    /// Ends this page's WebContent process (WebKit's `_killWebContentProcess`), so a live check can
    /// prove what the host does when the page crashes. False when WebKit has no such call. DEBUG
    /// verb only.
    public func debugKillWebContent() -> Bool {
        let selector = NSSelectorFromString("_killWebContentProcess")
        guard webView.responds(to: selector) else { return false }
        webView.perform(selector)
        return true
    }

    /// Whether a real AppKit key or mouse event reached the page in the last second: the same
    /// `PageCallContext.userGesture` a page call gets. DEBUG verb only.
    public var debugHasRecentUserGesture: Bool { recentUserGestureEvent() != nil }

    /// Clicks the first element matching `selector` from page script (not a user gesture);
    /// `metaKey` makes it a Cmd-click (a markdown link follows on Cmd-click while editing).
    /// `contextMenu`: a right-click (`contextmenu` at the element's top-left inset) instead of a click.
    public func debugClick(_ selector: String, metaKey: Bool = false, contextMenu: Bool = false) async -> Bool {
        let script = """
        const el = document.querySelector(selector); if (!el) { return false; }
        if (contextMenu) {
          const r = el.getBoundingClientRect();
          el.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 4, clientY: r.top + 4, view: window }));
          return true;
        }
        if (!metaKey) { el.click(); return true; }
        for (const type of ['mousedown', 'mouseup', 'click']) {
          el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, metaKey: true, view: window }));
        }
        return true;
        """
        let clicked = await callPageFunction(script, arguments: ["selector": selector, "metaKey": metaKey, "contextMenu": contextMenu])
        return clicked as? Bool == true
    }

    /// Moves the mouse onto the center of the first element matching `selector` (scrolled into
    /// view), so the page gets hover with no AppKit pointer: a capture slot's window never
    /// activates, and macOS sends an inactive window no mouse moves. Chromium gets a trusted
    /// DevTools `mouseMoved` (real `:hover`, `mouseenter`); WebKit gets page-script `mouseover`,
    /// `mouseenter` and `mousemove` (React's `onMouseEnter` listens to `mouseover`, so it runs, but
    /// `:hover` styles do not apply). Scrolling the element into view also scrolls its scrollers.
    /// `{hovered, native, x, y, width, height}` in CSS pixels; `{hovered: false}` when nothing matches or another
    /// element (an overlay, a clipping scroller) is at the element's center.
    public func debugHover(_ selector: String) async -> JSONValue {
        let script = """
        const el = document.querySelector(selector); if (!el) { return null; }
        el.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'instant' });
        const r = el.getBoundingClientRect();
        const x = r.left + r.width / 2, y = r.top + r.height / 2;
        const hit = el.contains(document.elementFromPoint(x, y));
        if (hit && !native) {
          for (const type of ['mouseover', 'mouseenter', 'mousemove']) {
            el.dispatchEvent(new MouseEvent(type, { bubbles: type !== 'mouseenter', clientX: x, clientY: y, view: window }));
          }
        }
        return JSON.stringify({ x, y, w: r.width, h: r.height, hit });
        """
        let page = chromiumSession?.page
        let native = page != nil
        guard let text = await callPageFunction(script, arguments: ["selector": selector, "native": native]) as? String,
              case .object(let point)? = try? JSONValue.parse(Data(text.utf8)),
              case .number(let x)? = point["x"], case .number(let y)? = point["y"] else { return ["hovered": false] }
        guard point["hit"] == true else { return ["hovered": false, "error": "another element is at its center"] }
        if let page {
            // DevTools input is in the viewport's CSS pixels, as `getBoundingClientRect` gives them:
            // Chromium scales it by the browser zoom, the embedding frame's CSS zoom and the pinch
            // scale itself (`InputHandler::ScaleFactor`). scripts/cmux-next/page-hover-zoom-live.py checks it at
            // UI scales 0.85 to 1.5.
            guard (try? await page.devTools("Input.dispatchMouseEvent", params: [
                "type": "mouseMoved", "x": x, "y": y, "button": "none", "buttons": 0, "modifiers": 0,
            ])) != nil else { return ["hovered": false, "error": "mouse move failed"] }
            // Only a hover the page now reports counts, so a move that missed never reads as one.
            let check = "const el = document.querySelector(selector); return !!el && el.matches(':hover');"
            guard await callPageFunction(check, arguments: ["selector": selector]) as? Bool == true else {
                return ["hovered": false, "error": "the element is not hovered after the move"]
            }
        }
        var hovered: [String: JSONValue] = ["hovered": true, "native": .bool(native), "x": .number(x), "y": .number(y)]
        // The element's size, for a caller checking the point against it; it never decides the hover.
        if case .number(let width)? = point["w"], case .number(let height)? = point["h"] {
            hovered["width"] = .number(width)
            hovered["height"] = .number(height)
        }
        return .object(hovered)
    }

    /// The zoom the page shows at in either engine (UI scale times the page's own zoom): page
    /// CSS pixels are view points divided by it.
    public var debugPageZoom: Double { pageZoom }

    /// A left click at `x`,`y` (CSS pixels, as `getBoundingClientRect` gives them) on a Chromium
    /// page: a trusted DevTools press and release, as a person's click, also in a window that never
    /// activates (a capture slot), where no AppKit click reaches the page. False on a WebKit page,
    /// which the caller clicks with AppKit events, or when DevTools refuses either half.
    public func debugPress(x: Double, y: Double) async -> Bool {
        guard let page = chromiumSession?.page else { return false }
        for type in ["mousePressed", "mouseReleased"] {
            guard (try? await page.devTools("Input.dispatchMouseEvent", params: [
                "type": type, "x": x, "y": y, "button": "left", "buttons": type == "mousePressed" ? 1 : 0,
                "clickCount": 1, "modifiers": 0,
            ])) != nil else { return false }
        }
        return true
    }

    /// Every element matching `selector` in document order: its `data-*` attributes, classes and
    /// first 120 characters of text (a list's order and row state as the page draws it).
    public func debugQuery(_ selector: String) async -> JSONValue {
        let script = """
        return JSON.stringify([...document.querySelectorAll(selector)].map((el) => ({
          data: Object.assign({}, el.dataset), classes: [...el.classList], text: (el.innerText || '').slice(0, 120) })));
        """
        guard let text = await callPageFunction(script, arguments: ["selector": selector]) as? String,
              let value = try? JSONValue.parse(Data(text.utf8)) else { return ["error": "query failed"] }
        return ["elements": value]
    }

    /// Focuses the first element matching `selector` (or keeps the focused one) and inserts `text`
    /// there as typed input (`insertText`), so live proofs can edit a page whose host has no
    /// Accessibility grant for real keystrokes. DEBUG verb only.
    public func debugInsertText(_ text: String, selector: String?) async -> Bool {
        let script = """
        const el = selector ? document.querySelector(selector) : document.activeElement;
        if (!el) { return false; }
        el.focus();
        return document.execCommand('insertText', false, text);
        """
        let inserted = await callPageFunction(script, arguments: ["selector": selector ?? NSNull(), "text": text])
        return inserted as? Bool == true
    }

    /// Writes the page as WebKit rendered it to `url` as PNG.
    public func debugSnapshot(to url: URL) async -> Bool {
        if let page = chromiumSession?.page {
            guard let json = try? await page.devTools("Page.captureScreenshot", params: ["format": "png"]),
                  let object = ChromiumPageHostWire.object(json), let base64 = object["data"] as? String,
                  let png = Data(base64Encoded: base64) else { return false }
            return (try? png.write(to: url)) != nil
        }
        keepRenderingWhenCovered()
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
        }
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// Whether pages keep drawing in an occluded window: automation launches only
    /// (`CMUX_NEXT_NO_ACTIVATE=1` or `CMUX_NEXT_SOCKET_MODE=automation`).
    /// `CMUX_NEXT_PAGES_WEBKIT_OCCLUSION=1` keeps WebKit's own throttling in an automation launch,
    /// so a live check can prove the user path (a covered window that comes back redraws).
    nonisolated public static func rendersWhenCovered(_ environment: [String: String]) -> Bool {
        guard environment["CMUX_NEXT_PAGES_WEBKIT_OCCLUSION"] != "1" else { return false }
        // The one automation rule for every window surface (terminals, pages).
        return WindowDrawPolicy.isAutomationLaunch(environment)
    }

    /// `-[WKWebView _setWindowOcclusionDetectionEnabled:]`, when this WebKit has it, so a tagged
    /// build behind other windows still renders.
    func keepRenderingWhenCovered() {
        Self.keepRenderingWhenCovered(webView)
    }

    /// The same for a web view no `PageWebView` owns (the agent pane's own, cx-zjtn.6).
    public static func keepRenderingWhenCovered(_ webView: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
        typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: SetEnabled.self)(webView, selector, false)
    }
}
#endif
