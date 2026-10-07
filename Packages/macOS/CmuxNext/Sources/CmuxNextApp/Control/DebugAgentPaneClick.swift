#if DEBUG
import AppKit
import CmuxNextAgentPane
import CmuxNextSettings
import WebKit

/// `debug.agent_pane {action: "click"}` (DEBUG builds): a native left click on one element of
/// the agent page, found by `selector` (CSS) or by `text` (its visible text or accessible name,
/// such as a chip's label; the smallest element that matches). The element's center goes from
/// page coordinates to the window, and a real mouse down and up go there the way
/// ``DebugNativeInput`` delivers them, so the pane's gesture monitor records the click as the
/// user's gesture, also in a window that was never activated. Never moves the user's pointer.
@MainActor
enum DebugAgentPaneClick {
    /// Finds the element, scrolls it into view and returns its center in CSS pixels.
    private static let locate = """
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
        target.scrollIntoView({ block: 'nearest', inline: 'nearest' });
        const r = target.getBoundingClientRect();
        return JSON.stringify({ x: r.left + r.width / 2, y: r.top + r.height / 2, tag: target.tagName.toLowerCase() });
        """

    static func click(_ params: [String: JSONValue], pane: String, view: AgentPaneView, services: AppServices) async -> JSONValue {
        let selector = params["selector"]?.stringValue ?? ""
        let text = params["text"]?.stringValue ?? ""
        guard !selector.isEmpty || !text.isEmpty else {
            return .object(["pane": .string(pane), "error": .string("pass selector or text")])
        }
        let found: [String: Any]
        do {
            let result = try await view.webView.callAsyncJavaScript(
                locate, arguments: ["selector": selector, "text": text], in: nil, contentWorld: .page)
            guard let json = result as? String,
                  let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                return .object(["pane": .string(pane), "error": .string("the page returned no JSON")])
            }
            found = object
        } catch {
            return .object(["pane": .string(pane), "error": .string(String(describing: error))])
        }
        if let error = found["error"] as? String { return .object(["pane": .string(pane), "error": .string(error)]) }
        guard let x = found["x"] as? Double, let y = found["y"] as? Double, let window = view.window else {
            return .object(["pane": .string(pane), "error": .string("the pane is not in a window")])
        }
        let webView = view.webView
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
        let delivered: String
        if DebugNativeInput.usesAppKitPath(window) {
            DebugNativeInput.sendThroughApp([down, up])
            delivered = "app"
        } else {
            // The local monitor sees mouse downs only.
            DebugNativeInput.runPaneMonitors(down, in: window, services: services)
            SyntheticInput.register([down, up])
            webView.mouseDown(with: down)
            webView.mouseUp(with: up)
            delivered = "view"
        }
        let gestures = view.model.transport.gestures.debugState
        return .object([
            "pane": .string(pane), "clicked": .bool(true), "tag": (found["tag"] as? String).map(JSONValue.string) ?? .null,
            "window_x": .number(Double(point.x)), "window_y": .number(Double(point.y)), "delivered": .string(delivered),
            "gesture_available": .bool(gestures.available),
        ])
    }
}
#endif
