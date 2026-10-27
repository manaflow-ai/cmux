#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextBrowser
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
    /// A hosted page (host mode, ``DebugKey/hostPage(of:in:)``) has no window: the press and release
    /// go to the view under the point in the cmux window, by the same rule (``clickHostPage(_:services:)``).
    static func clickPage(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        let controller = services.windows.controllers.first { windowID == nil || $0.state.id == windowID }
        guard let controller, let pane = params["pane"]?.stringValue ?? controller.focus.state.pane else {
            return .object(["error": .string("no window or pane")])
        }
        if let target = hostPage(params, services: services) { return clickHostPage(target, services: services) }
        guard let page = DebugKey.pageWindow(of: pane, in: controller), let content = page.contentView else {
            return noPageWindow(pane, in: controller)
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

    /// `debug.mouse {"action": "move", "target": "page"}`: a pointer move with no button over the Chromium page
    /// of `pane` (default: the focused pane), at `x`,`y` (top-left points in the page) or its center: hover, so
    /// the renderer computes the cursor and hover styles there. Host mode: the page view's own mouse path, which
    /// sends a MOUSE frame to the Chromium Host (a move reaches a view through its tracking area, which the window
    /// server drives, not through `sendEvent`'s hit test, so the view gets it directly); in process: the page
    /// window's view under the point, as ``clickPage(_:services:)`` hands it clicks. A host-mode page view with no
    /// pointer route to the host answers an error with `reason` `no_host_input_route`, never a move that reaches
    /// no renderer.
    static func movePage(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        let controller = services.windows.controllers.first { windowID == nil || $0.state.id == windowID }
        guard let controller, let pane = params["pane"]?.stringValue ?? controller.focus.state.pane else {
            return .object(["error": .string("no window or pane")])
        }
        if let target = hostPage(params, services: services) {
            guard let event = mouse(.mouseMoved, at: target.topLeft, in: target.window, flags: [], clicks: 0) else {
                return .object(["error": .string("could not synthesize the move")])
            }
            target.page.mouseMoved(with: event)
            // The synthesized pointer is there too, so hover (the page's tooltip) sees it over the page.
            LayoutRootView.setDebugPointer(baseLocation(target.topLeft, in: target.window), in: target.window)
            return .object(["window": .string(target.windowID), "x": .number(target.point.x), "y": .number(target.point.y),
                            "view": .string("ChromiumHostPageView"), "delivered": .number(1)])
        }
        guard let page = DebugKey.pageWindow(of: pane, in: controller), let content = page.contentView else {
            return noPageWindow(pane, in: controller)
        }
        let point = NSPoint(x: params["x"]?.doubleValue ?? content.bounds.width / 2, y: params["y"]?.doubleValue ?? content.bounds.height / 2)
        guard let event = mouse(.mouseMoved, at: point, in: page, flags: [], clicks: 0), let frame = content.superview,
              let target = frame.hitTest(frame.convert(event.locationInWindow, from: nil)) else {
            return .object(["error": .string("no view under the point")])
        }
        target.mouseMoved(with: event)
        return .object(["window": .string(controller.state.id), "x": .number(point.x), "y": .number(point.y),
                        "view": .string(String(describing: type(of: target))), "delivered": .number(1)])
    }

    /// AppKit's button numbers of the page buttons past left and right (`debug.mouse` page `click` with `button`).
    static let pageButtons: [String: Int64] = ["middle": 2, "back": 3, "forward": 4]

    /// The hosted page view of `params`' pane (default: the focused pane) when it takes the page's pointer
    /// (``DebugKey/hostPage(of:in:)`` with a route to the host), and the point `x`,`y` (top-left points in the
    /// page, default its center) in its window's top-left points.
    private static func hostPage(_ params: [String: JSONValue], services: AppServices)
        -> (windowID: String, window: NSWindow, page: ChromiumHostPageView, point: NSPoint, topLeft: NSPoint)? {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let window = controller.window, let pane = params["pane"]?.stringValue ?? controller.focus.state.pane,
              let page = DebugKey.hostPage(of: pane, in: controller), page.takesPagePointer else { return nil }
        let size = page.bounds.size
        let point = NSPoint(x: params["x"]?.doubleValue ?? size.width / 2, y: params["y"]?.doubleValue ?? size.height / 2)
        let base = page.convert(NSPoint(x: point.x, y: size.height - point.y), to: nil)
        return (controller.state.id, window, page, point, NSPoint(x: base.x, y: baseLocation(.zero, in: window).y - base.y))
    }

    /// A left click on a hosted page view, at the view a real click there hits. The key window takes the app's
    /// path (`CmuxApplication.sendEvent`, local monitors). A window that is not key never gets the click through
    /// `sendEvent`, which would make it key and hold the first click back (`acceptsFirstMouse`), as for the
    /// in-process page window above: the panes' gesture monitors run, then, inside the app's input dispatch with
    /// a latency slot, the view under the point takes the keyboard when it is in the page (as AppKit's click
    /// gives it) and gets the press and release, which send the MOUSE frames to the host. `view` names the view
    /// under the point and `on_page` whether it is the page view or inside it (a find bar over the page is not).
    private static func clickHostPage(_ target: (windowID: String, window: NSWindow, page: ChromiumHostPageView, point: NSPoint, topLeft: NSPoint),
                                      services: AppServices) -> JSONValue {
        let window = target.window
        guard let down = mouse(.leftMouseDown, at: target.topLeft, in: window, flags: [], clicks: 1),
              let up = mouse(.leftMouseUp, at: target.topLeft, in: window, flags: [], clicks: 1),
              let frame = window.contentView?.superview,
              let hit = frame.hitTest(frame.convert(down.locationInWindow, from: nil)) else {
            return .object(["error": .string("no view under the point")])
        }
        if DebugNativeInput.usesAppKitPath(window) {
            DebugNativeInput.sendThroughApp([down, up])
        } else {
            SyntheticInput.register([down, up])
            let onPage = hit.isDescendant(of: target.page)
            for event in [down, up] {
                DebugNativeInput.runPaneMonitors(event, in: window, services: services)
                let slot = services.inputLatency.willDeliver(event, in: window, to: hit)
                services.inputDispatch.dispatching(event) {
                    if event.type == .leftMouseDown {
                        if onPage { window.makeFirstResponder(target.page) }
                        hit.mouseDown(with: event)
                    } else {
                        hit.mouseUp(with: event)
                    }
                }
                if let slot { services.inputLatency.didDispatch(slot, layoutTookScroll: false) }
            }
        }
        return .object(["window": .string(target.windowID), "x": .number(target.point.x), "y": .number(target.point.y),
                        "view": .string(String(describing: type(of: hit))), "on_page": .bool(hit.isDescendant(of: target.page)),
                        "page_input": .string("hosted_view"), "delivered": .number(2)])
    }

    /// The reply when `pane` shows no page window: `no_host_input_route` when a hosted page view is there (one
    /// that takes no pointer, or has no route to the Chromium Host yet), else no page at all.
    private static func noPageWindow(_ pane: String, in controller: WindowController) -> JSONValue {
        guard let view = controller.content?.paneController(key: pane)?.view, ChromiumHostPageView.first(in: view) != nil else {
            return .object(["error": .string("no Chromium page for pane")])
        }
        return .object(["error": .string("the page view has no pointer route to the Chromium Host (p01-process-042)"),
                        "reason": .string("no_host_input_route")])
    }

    /// `debug.mouse {"target": "page", "button": "middle" | "back" | "forward"}` (host mode): a press and release of
    /// that button on the page view at `x`,`y` (top-left points in the page) or its center, through the view's own
    /// `otherMouseDown`/`otherMouseUp` (chromium-host-bench.py's button rows: a back or forward press must never
    /// reach the page as a left click). An error with `reason` `not_host_mode` for a page view that takes no pointer.
    static func buttonPage(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let name = params["button"]?.stringValue ?? ""
        guard let number = pageButtons[name] else { return .object(["error": .string("no such page button: " + name)]) }
        guard let target = hostPage(params, services: services) else {
            return .object(["error": .string("no host-mode page view that takes the pointer"), "reason": .string("not_host_mode")])
        }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            guard let made = mouse(type, at: target.topLeft, in: target.window, flags: [], clicks: 1),
                  let cg = made.cgEvent?.copy() else { return nil }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: number)
            return keepingWindowPoint(cg, made.locationInWindow)
        }
        guard let down = event(.otherMouseDown), let up = event(.otherMouseUp) else {
            return .object(["error": .string("could not synthesize the " + name + " click")])
        }
        target.page.otherMouseDown(with: down)
        target.page.otherMouseUp(with: up)
        return .object(["window": .string(target.windowID), "x": .number(target.point.x), "y": .number(target.point.y),
                        "button_number": .number(Double(number)), "delivered": .number(2)])
    }

    /// `debug.mouse {"action": "pinch" | "smart_magnify", "target": "page"}` (host mode): the kGesture frames a
    /// trackpad pinch by `scale` (default 1.5) or a two-finger double tap sends from the page view, at `x`,`y`
    /// (top-left points in the page) or its center (``ChromiumHostPageView/debugGesture(pinchScale:at:)``: AppKit
    /// makes no magnify event). `frames`: how many went to the host. An error with `reason` `not_host_mode` for a
    /// page view that takes no pointer.
    static func gesturePage(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let target = hostPage(params, services: services) else {
            return .object(["error": .string("no host-mode page view that takes the pointer"), "reason": .string("not_host_mode")])
        }
        let scale = params["action"]?.stringValue == "pinch" ? CGFloat(params["scale"]?.doubleValue ?? 1.5) : nil
        let frames = target.page.debugGesture(pinchScale: scale, at: target.point)
        return .object(["window": .string(target.windowID), "x": .number(target.point.x), "y": .number(target.point.y),
                        "frames": .number(Double(frames))])
    }

    /// `debug.mouse {"action": "scroll", "target": "page"}`: one scroll event over a Chromium page, at `x`,`y`
    /// (top-left points in the main window, as a plain scroll takes them) or the center of `pane`'s page
    /// (default: the focused pane). The event goes to the page window under that point, as the window server
    /// picks it (``WindowOverlayHost/frontPageWindow(at:in:)``), so a fixed pointer stays fixed while a pan
    /// slides other pages under it. It takes the layout's part of a real scroll's path over a page: the
    /// layout's routing sees it first as an event of that page window
    /// (``LayoutRootView/handleMonitoredScroll(_:from:at:)``), and an event the layout does not take goes to
    /// the page view under the point. Both run inside the app's input dispatch context with a latency slot, so
    /// the scroll is timed to its frame (`key.scroll_frame`). `delivered_to` names who took it, as for a plain scroll; an error
    /// when no page is under the point. A hosted page (host mode) has no window: over it the scroll is a plain
    /// `scroll` at that point, which the layout and then the page view take as for any view of the window.
    ///
    /// Not on the path: `NSApp.sendEvent`, `NSWindow.sendEvent` and every other local event monitor (the
    /// Chromium swipe's `CEFSwipeNavigation`, `HoverCardCoordinator`, `NewTabPreload`'s input note). A
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
        // A hosted page (host mode) is a view of this window: the scroll takes the plain path of a scroll over
        // any view of the window, at the asked point or the page's center.
        let hostedPoint: NSPoint? = if let asked { hostedPageUnder(asked, in: window) ? asked : nil }
            else { hostPage(params, services: services)?.topLeft }
        if let point = hostedPoint {
            var plain = params
            plain["target"] = nil
            plain["x"] = .number(point.x)
            plain["y"] = .number(point.y)
            return send(plain, services: services)
        }
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
        let latencySlot = services.inputLatency.willDeliver(event, in: page, to: target)
        let layoutTook = services.inputDispatch.dispatching(event) { () -> Bool in
            if root.handleMonitoredScroll(event, from: page, at: location) == nil { return true }
            target.scrollWheel(with: event)
            return false
        }
        if let latencySlot { services.inputLatency.didDispatch(latencySlot, layoutTookScroll: layoutTook) }
        if params["hover"]?.boolValue != false { LayoutRootView.setDebugPointer(mainPoint, in: window) }
        let top = InputJournal.topLeftPoint(mainPoint, in: window, relativeTo: window)
        return .object(["window": .string(controller.state.id), "x": .number(top.x), "y": .number(top.y),
                        "delivered_to": .string(layoutTook ? "LayoutRootView" : String(describing: type(of: target)))])
    }

    /// Whether the view under `point` (top-left window points) is a hosted page view that takes the page's input, or inside one.
    private static func hostedPageUnder(_ point: NSPoint, in window: NSWindow) -> Bool {
        guard let frame = window.contentView?.superview, let hit = frame.hitTest(frame.convert(baseLocation(point, in: window), from: nil)) else {
            return false
        }
        return sequence(first: hit, next: \.superview).contains { ($0 as? ChromiumHostPageView)?.takesPageInput == true }
    }
}
#endif
