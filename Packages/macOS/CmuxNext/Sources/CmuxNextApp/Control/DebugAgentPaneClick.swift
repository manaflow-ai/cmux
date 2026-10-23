#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextAgentPane
import CmuxNextSettings
import WebKit

/// `debug.agent_pane {action: "click"}` (DEBUG builds): a native left click on one element of the agent page,
/// found by `selector` (CSS) or by `text` (its visible text or accessible name, such as a chip's label; the
/// smallest element that matches). Its center goes from page coordinates to the window, and a real mouse down and
/// up go there as ``DebugNativeInput`` delivers them, so the pane's gesture monitor records the user's gesture,
/// also in a window that was never activated. A chat shown in Chromium gets a trusted DevTools press instead,
/// which the gesture monitor does not see. Never moves the user's pointer.
@MainActor
enum DebugAgentPaneClick {
    /// Whether the page has seen the click's mouse down, waiting up to `ms` for it.
    private static let arrived = """
        for (const until = Date.now() + ms; Date.now() < until; await new Promise((resolve) => setTimeout(resolve, 20))) {
            if ((window.__cmuxDebugClick ?? []).some((type) => type.startsWith('mousedown'))) return true;
        }
        return false;
        """

    /// After the click: the page's events (`?` marks an untrusted one), its visibility and focus.
    private static let report = """
        await new Promise((resolve) => setTimeout(resolve, 300));
        return JSON.stringify({ events: window.__cmuxDebugClick ?? [], visibility: document.visibilityState, focus: document.hasFocus() });
        """

    static func click(_ params: [String: JSONValue], pane: String, view: AgentPaneView, services: AppServices) async -> JSONValue {
        let selector = params["selector"]?.stringValue ?? ""
        let text = params["text"]?.stringValue ?? ""
        guard !selector.isEmpty || !text.isEmpty else {
            return .object(["pane": .string(pane), "error": .string("pass selector or text")])
        }
        // In the page the chat shows: on the shared page host, the pane's own web view holds no document.
        let found = await view.debugLocate(selector: selector, text: text)
        if let error = found["error"] as? String { return .object(["pane": .string(pane), "error": .string(error)]) }
        guard let x = found["x"] as? Double, let y = found["y"] as? Double else {
            return .object(["pane": .string(pane), "error": .string("the page returned no point")])
        }
        // A chat in Chromium takes a trusted DevTools click: no AppKit click reaches its page in a window
        // that never activates (a capture slot).
        if view.debugShowsChromium {
            let pressed = await view.debugPress(x: x, y: y)
            let page = (try? await view.callPageScript(report)) as? String
            let pageObject = page.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            return .object([
                "pane": .string(pane), "clicked": .bool(pressed), "tag": (found["tag"] as? String).map(JSONValue.string) ?? .null,
                "x": .number(x), "y": .number(y), "delivered": .string("devtools"),
                "gesture_available": .bool(view.model.transport.gestures.debugState.available),
                "page_events": .array(((pageObject?["events"] as? [String]) ?? []).map(JSONValue.string)),
            ])
        }
        guard let webView = view.debugPageWebView, let window = webView.window else {
            return .object(["pane": .string(pane), "error": .string("the pane is not in a window")])
        }
        let scale = webView.pageZoom * webView.magnification
        let (cssX, cssY) = (CGFloat(x) * scale, CGFloat(y) * scale)
        let local = NSPoint(x: cssX, y: webView.isFlipped ? cssY : webView.bounds.height - cssY)
        let point = webView.convert(local, to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp) else {
            return .object(["pane": .string(pane), "error": .string("could not synthesize events")])
        }
        // What a real click at this point reaches: the window's hit test, from its frame view.
        let frameView = window.contentView?.superview
        let hit = frameView.flatMap { $0.hitTest($0.convert(point, from: nil)) }
        // `path`: "app" or "view" forces one delivery path; by default the key window takes the app's.
        let path = params["path"]?.stringValue
        var delivered: String
        if path == "app" || (path != "view" && DebugNativeInput.usesAppKitPath(window)) {
            DebugNativeInput.sendThroughApp([down, up])
            delivered = "app"
            // Automation makes a window key without the app being frontmost, and AppKit then holds a first click back from a
            // view that does not accept first mouse (the web view): when the click was this page's and the page never saw it,
            // it goes to the web view as for a window that is not key. A click AppKit gave another view stays there.
            let pageSawIt = (try? await view.callPageScript(arrived, arguments: ["ms": 500])) as? Bool
            if path != "app", pageSawIt == false, hit?.isDescendant(of: webView) == true {
                webView.mouseDown(with: down); webView.mouseUp(with: up)
                delivered = "app, then view"
            }
        } else {
            DebugNativeInput.runPaneMonitors(down, in: window, services: services) // the local monitor sees mouse downs only
            SyntheticInput.register([down, up])
            // As AppKit's click does, inside an input event: the clicked web view takes the keyboard (AgentPaneView.refusesSelfFocus).
            let app = NSApp as? CmuxApplication, outer = app?.isHandlingSendEvent() ?? false; app?.setHandlingSendEvent(true)
            if hit?.isDescendant(of: webView) == true { window.makeFirstResponder(webView) }
            webView.mouseDown(with: down); webView.mouseUp(with: up); app?.setHandlingSendEvent(outer)
            delivered = "view"
        }
        let gestures = view.model.transport.gestures.debugState
        let page = (try? await view.callPageScript(report)) as? String
        let pageObject = page.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        return .object([
            "pane": .string(pane), "clicked": .bool(true), "tag": (found["tag"] as? String).map(JSONValue.string) ?? .null,
            "window_x": .number(Double(point.x)), "window_y": .number(Double(point.y)), "delivered": .string(delivered),
            "gesture_available": .bool(gestures.available),
            "hit": hit.map { .string(String(describing: type(of: $0))) } ?? .null,
            "hit_in_page": .bool(hit?.isDescendant(of: webView) == true),
            "page_events": .array(((pageObject?["events"] as? [String]) ?? []).map(JSONValue.string)),
            "page_visibility": (pageObject?["visibility"] as? String).map(JSONValue.string) ?? .null,
            "page_focus": (pageObject?["focus"] as? Bool).map(JSONValue.bool) ?? .null,
        ])
    }

    /// Moves the page's pointer to `x`,`y` in CSS pixels: pointer and mouse out of the element it
    /// leaves, over the one it enters, and a move, as the page sees a real pointer (untrusted).
    private static let hoverScript = """
        const now = document.elementFromPoint(x, y);
        const was = window.__cmuxDebugHover ?? null;
        const fire = (target, type, related) => {
            if (!target) return;
            const init = { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, relatedTarget: related };
            target.dispatchEvent(type.startsWith('pointer') ? new PointerEvent(type, { ...init, pointerType: 'mouse', isPrimary: true }) : new MouseEvent(type, init));
        };
        if (was !== now) {
            fire(was, 'pointerout', now); fire(was, 'mouseout', now);
            fire(now, 'pointerover', was); fire(now, 'mouseover', was);
            window.__cmuxDebugHover = now;
        }
        fire(now, 'pointermove', null); fire(now, 'mousemove', null);
        return now ? now.tagName.toLowerCase() + (now.getAttribute('title') ? ' title=' + now.getAttribute('title') : '') : '';
        """

    /// `debug.agent_pane {action: "hover", x, y}`: the page's pointer moves to window point `x`,`y`
    /// (top-left origin, as `debug.mouse`): the page gets the pointer events a real move there
    /// fires (untrusted, and no CSS `:hover`). WebKit takes no mouse moves in a window that is not
    /// key, and a capture slot's never is: recordings of the page's tooltips and hints there.
    static func hover(_ params: [String: JSONValue], pane: String, view: AgentPaneView) async -> JSONValue {
        guard let window = view.window, let x = params["x"]?.doubleValue, let y = params["y"]?.doubleValue else {
            return .object(["pane": .string(pane), "error": .string("pass x and y; the pane must be in a window")])
        }
        // The view that shows the chat: the page host's (WebKit or Chromium) or the pane's own.
        let shown = view.focusTarget
        let height = window.contentView?.bounds.height ?? window.frame.height
        let local = shown.convert(NSPoint(x: x, y: height - y), from: nil)
        let scale = max(view.debugPageZoom, 0.01)
        let cssX = local.x / scale
        let cssY = (shown.isFlipped ? local.y : shown.bounds.height - local.y) / scale
        do {
            let hit = try await view.callPageScript(hoverScript, arguments: ["x": Double(cssX), "y": Double(cssY)]) as? String
            return .object(["pane": .string(pane), "x": .number(x), "y": .number(y), "element": .string(hit ?? "")])
        } catch {
            return .object(["pane": .string(pane), "error": .string(String(describing: error))])
        }
    }
}
#endif
