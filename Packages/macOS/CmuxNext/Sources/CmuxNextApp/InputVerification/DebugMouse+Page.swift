#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextSettings

extension DebugMouse {
    /// `debug.mouse {"target": "page"}`: a left click on the Chromium page of `pane` (default: the
    /// focused pane), at `x`,`y` (top-left points in the page) or its center. The page window is
    /// never key in a no-activate run, so AppKit would make it key and drop a posted click
    /// instead of passing it through; the press and release go to the view under the point, as
    /// AppKit hands them on when the window is key. Chromium's view forwards them to the renderer
    /// and waits for its answer, so a hung page's hang timer starts (cx-d0d.36). `delivered`
    /// counts the events a view got. No system event and no other app.
    static func clickPage(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        let controller = services.windows.controllers.first { windowID == nil || $0.state.id == windowID }
        guard let controller, let pane = params["pane"]?.stringValue ?? controller.focus.state.pane,
              let page = DebugKey.pageWindow(of: pane, in: controller), let content = page.contentView else {
            return .object(["error": .string("no Chromium page window for pane")])
        }
        let size = content.bounds.size
        let point = NSPoint(x: params["x"]?.doubleValue ?? size.width / 2, y: params["y"]?.doubleValue ?? size.height / 2)
        let events = [mouse(.leftMouseDown, at: point, in: page, flags: [], clicks: 1),
                      mouse(.leftMouseUp, at: point, in: page, flags: [], clicks: 1)].compactMap { $0 }
        guard events.count == 2, let frame = content.superview,
              let target = frame.hitTest(frame.convert(events[0].locationInWindow, from: nil)) else {
            return .object(["error": .string("no view under the point")])
        }
        target.mouseDown(with: events[0])
        target.mouseUp(with: events[1])
        return .object(["window": .string(controller.state.id), "x": .number(point.x), "y": .number(point.y),
                        "view": .string(String(describing: type(of: target))), "delivered": .number(2)])
    }
}
#endif
