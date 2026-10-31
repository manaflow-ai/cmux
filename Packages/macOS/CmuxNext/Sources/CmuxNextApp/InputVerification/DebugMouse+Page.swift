#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextDesign
import CmuxNextLayout
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

    /// `debug.mouse {"action": "scroll", "target": "page"}`: one scroll event over a Chromium page, at `x`,`y`
    /// (top-left points in the main window, as a plain scroll takes them) or the center of `pane`'s page
    /// (default: the focused pane). The event goes to the page window under that point, as the window server
    /// picks it (``WindowOverlayHost/frontPageWindow(at:in:)``), so a fixed pointer stays fixed while a pan
    /// slides other pages under it. It takes the layout's part of a real scroll's path over a page: the
    /// layout's routing sees it first as an event of that page window
    /// (``LayoutRootView/handleMonitoredScroll(_:from:at:)``), and an event the layout does not take goes to
    /// the page view under the point. Both run inside the app's input dispatch context, so the scroll is timed
    /// to its frame (`key.scroll_frame`). `delivered_to` names who took it, as for a plain scroll; an error
    /// when no page is under the point.
    ///
    /// Not on the path: `NSApp.sendEvent`, `NSWindow.sendEvent` and every other local event monitor (the
    /// Chromium swipe's `CEFSwipeNavigation`, `HoverCardCoordinator`, `NewTabSparePool`'s input note). A
    /// synthesized scroll has no window AppKit can route it to, and a queued event would answer after the
    /// reply, so this calls the layout and the view directly, as the plain `scroll` action does. A bench that
    /// uses it measures the layout's routing and pan, not those monitors' per-event work.
    static func scrollPage(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        let controller = services.windows.controllers.first { windowID == nil || $0.state.id == windowID }
        guard let controller, let window = controller.window, let root = controller.content?.layoutView else {
            return .object(["error": .string("no window")])
        }
        // The pointer: the asked main-window point, else the center of the pane's page.
        let asked = params["x"]?.doubleValue.flatMap { x in params["y"]?.doubleValue.map { NSPoint(x: x, y: $0) } }
        let mainPoint: NSPoint
        if let asked {
            mainPoint = baseLocation(asked, in: window)
        } else if let pane = params["pane"]?.stringValue ?? controller.focus.state.pane,
                  let paged = DebugKey.pageWindow(of: pane, in: controller), let content = paged.contentView {
            mainPoint = window.convertPoint(fromScreen: paged.convertPoint(toScreen: NSPoint(x: content.bounds.midX, y: content.bounds.midY)))
        } else {
            return .object(["error": .string("pass x and y, or a pane that shows a Chromium page")])
        }
        let screenPoint = window.convertPoint(toScreen: mainPoint)
        guard let page = WindowOverlayHost.frontPageWindow(at: screenPoint, in: window), let content = page.contentView,
              let frame = content.superview else {
            return .object(["error": .string("no Chromium page window under the point")])
        }
        let location = page.convertPoint(fromScreen: screenPoint)
        let flags = modifiers(params["modifiers"]?.arrayValue ?? [])
        guard let event = scroll(atBase: location, in: page, dx: params["dx"]?.doubleValue ?? 0, dy: params["dy"]?.doubleValue ?? 0,
                                 phase: params["phase"]?.stringValue, flags: flags),
              let target = frame.hitTest(frame.convert(location, from: nil)) else {
            return .object(["error": .string("could not synthesize the page scroll")])
        }
        let layoutTook = services.inputDispatch.dispatching(event) { () -> Bool in
            if root.handleMonitoredScroll(event, from: page, at: location) == nil { return true }
            target.scrollWheel(with: event)
            return false
        }
        if params["hover"]?.boolValue != false { LayoutRootView.setDebugPointer(mainPoint, in: window) }
        let top = InputJournal.topLeftPoint(mainPoint, in: window, relativeTo: window)
        return .object(["window": .string(controller.state.id), "x": .number(top.x), "y": .number(top.y),
                        "delivered_to": .string(layoutTook ? "LayoutRootView" : String(describing: type(of: target)))])
    }
}
#endif
