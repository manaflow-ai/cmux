#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import CmuxNextLayout
import CmuxNextSettings

/// `debug.mouse` (DEBUG builds): synthesized mouse events for one of this
/// process's own windows, posted to the app's event queue so they take the
/// path real ones take: `CmuxApplication.sendEvent` (journal, key router),
/// local event monitors (the layout's focus-on-mouse-down), the window's
/// `sendEvent`, hit testing, and any view's tracking loop, which reads the
/// following drag and up events from the same queue. The user's pointer
/// never moves and no other app is touched.
///
/// Params: `window` (id; default the first window); a point as `x`,`y`
/// (window-local points from the top-left, as the journal records them) or
/// `pane` (the center of that pane's content) or `row` (a sidebar workspace row, `DebugMouse+Rows`) or `divider` (a pane
/// divider's center, `DebugMouse+Rows`); `action`: `click` (default),
/// `double_click`, `down`, `up`, `drag` (to `to_x`,`to_y`
/// or `to_edge` of the shown workspace, in `steps`), `move` (pointer motion with no button, for hover: tab and workspace
/// hover cards), `hover` (tracking-area owners get entered, moved and
/// exited at once, `DebugHover`: the tab strip's hover reveal), or `scroll`
/// (`dx`,`dy` pixels; `phase` began/changed/ended makes it a trackpad
/// gesture event); a `drag` takes `press: false` (no mouse-down: it
/// continues a drag left open) and `release: false` (no mouse-up: the drag
/// stays open for `debug.tab_drag` and screenshots); `button`: `left`
/// (default), `right`, `middle` (AppKit's `otherMouse*` events, button
/// number 2: a middle click on a sidebar workspace row closes it);
/// `modifiers`: `cmd`, `shift`, `option`, `ctrl` (a `scroll` carries them
/// too: Command + scroll moves the layout, `layout.scrollModifier`). Every action also moves
/// the synthesized pointer that layout hover reads (`LayoutRootView.
/// setDebugPointer`); `leave` moves it out of the window. A `scroll` with
/// `hover: false` leaves the synthesized pointer as it is, so a perf
/// gesture measures the scroll, not a hover recompute per event (set the
/// pointer once with the gesture's first event). `target: "page"`
/// clicks Chromium's page view instead (`DebugMouse+Page`).
enum DebugMouse {
    static func send(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        if params["target"]?.stringValue == "page" {
            return params["action"]?.stringValue == "scroll" ? scrollPage(params, services: services) : clickPage(params, services: services)
        }
        if params["target"]?.stringValue == "hover-card" { return hoverCard(params, services: services) }
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let window = controller.window else { return .object(["error": .string("no window")]) }
        guard let point = point(params, controller: controller, window: window) else {
            return .object(["error": .string("pass x and y, a pane shown in the window, or a workspace row in its sidebar")])
        }
        let flags = modifiers(params["modifiers"]?.arrayValue ?? [])
        let (down, up, dragged) = eventTypes(button: params["button"]?.stringValue)
        let action = params["action"]?.stringValue ?? "click"
        var events: [NSEvent?] = []
        switch action {
        case "click":
            events = [mouse(down, at: point, in: window, flags: flags, clicks: 1), mouse(up, at: point, in: window, flags: flags, clicks: 1)]
        case "double_click":
            events = (1...2).flatMap { clicks in
                [mouse(down, at: point, in: window, flags: flags, clicks: clicks), mouse(up, at: point, in: window, flags: flags, clicks: clicks)]
            }
        case "down":
            events = [mouse(down, at: point, in: window, flags: flags, clicks: 1)]
        case "up":
            events = [mouse(up, at: point, in: window, flags: flags, clicks: 1)]
        case "drag":
            let target = dragTarget(params, from: point, controller: controller, window: window)
            let steps = min(max(params["steps"]?.intValue ?? 12, 1), 200)
            events = params["press"]?.boolValue == false ? [] : [mouse(down, at: point, in: window, flags: flags, clicks: 1)]
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let at = NSPoint(x: point.x + (target.x - point.x) * t, y: point.y + (target.y - point.y) * t)
                events.append(mouse(dragged, at: at, in: window, flags: flags, clicks: 1))
            }
            if params["release"]?.boolValue != false { events.append(mouse(up, at: target, in: window, flags: flags, clicks: 1)) }
        case "move":
            // A posted move reaches no tracking area (the window server
            // drives those), so their owners get it too: the tab strip and
            // sidebar open hover cards on a capture slot.
            _ = DebugHover.move(to: baseLocation(point, in: window), in: window)
            events = [mouse(.mouseMoved, at: point, in: window, flags: flags, clicks: 0)]
        case "scroll":
            guard let event = scroll(at: point, in: window, dx: params["dx"]?.doubleValue ?? 0, dy: params["dy"]?.doubleValue ?? 0,
                                     phase: params["phase"]?.stringValue, flags: flags) else {
                return .object(["error": .string("could not synthesize events")])
            }
            guard event.window == nil else {
                events = [event]
                break
            }
            // NSEvent(cgEvent:) leaves a synthesized scroll's window nil, so
            // the app would hit-test the screen point as a window point and
            // the wheel would reach no view. Deliver it to the view under
            // the point instead; its responder chain finds the scroll view.
            guard let frameView = window.contentView?.superview,
                  let target = frameView.hitTest(frameView.convert(baseLocation(point, in: window), from: nil)) else {
                return .object(["error": .string("no view under the point")])
            }
            // A real scroll first meets the layout's event monitor (strip and
            // row scrolls); a windowless synthesized one skips monitors, so
            // the layout under the point gets it first, then the view. Both run
            // inside the app's input dispatch context, as sendEvent's do, so the
            // scroll is timed to its frame the same way (`key.scroll_frame`).
            let root = sequence(first: target, next: \.superview).lazy.compactMap { $0 as? LayoutRootView }.first
            let movesPointer = params["hover"]?.boolValue != false
            let layoutTook = services.inputDispatch.dispatching(event) { () -> Bool in
                if let root, root.handleScroll(event, locationInWindow: baseLocation(point, in: window)) { return true }
                target.scrollWheel(with: event)
                return false
            }
            if layoutTook {
                if movesPointer { LayoutRootView.setDebugPointer(baseLocation(point, in: window), in: window) }
                return .object(["window": .string(controller.state.id), "x": .number(point.x), "y": .number(point.y),
                                "delivered_to": .string("LayoutRootView")])
            }
            if movesPointer { LayoutRootView.setDebugPointer(baseLocation(point, in: window), in: window) }
            return .object(["window": .string(controller.state.id), "x": .number(point.x), "y": .number(point.y),
                            "delivered_to": .string(String(describing: type(of: target)))])
        case "leave":
            // The synthesized pointer leaves the window (divider hover clears).
            LayoutRootView.setDebugPointer(nil, in: window)
            return .object(["window": .string(controller.state.id)])
        case "hover":
            // Hover: tracking-area owners get the events at once (DebugHover).
            let delivered = DebugHover.move(to: baseLocation(point, in: window), in: window)
            LayoutRootView.setDebugPointer(baseLocation(point, in: window), in: window)
            return .object(["window": .string(controller.state.id), "x": .number(point.x), "y": .number(point.y),
                            "delivered": .number(Double(delivered)), "crossings": .array(DebugHover.lastCrossings.map(JSONValue.string))])
        default:
            return .object(["error": .string("unknown action \(action)")])
        }
        let posted = events.compactMap { $0 }
        guard posted.count == events.count else { return .object(["error": .string("could not synthesize events")]) }
        // The layout's hover reads the pointer, not events: the synthesized
        // pointer ends where the last event is (cx-ww20).
        let last = action == "drag" ? dragTarget(params, from: point, controller: controller, window: window) : point
        if action != "scroll" || params["hover"]?.boolValue != false { LayoutRootView.setDebugPointer(baseLocation(last, in: window), in: window) }
        // Agent input: never the user choosing the app (no-activate guard).
        SyntheticInput.register(posted)
        for event in posted { NSApp.postEvent(event, atStart: false) }
        return .object([
            "window": .string(controller.state.id),
            "x": .number(point.x), "y": .number(point.y),
            "posted": .number(Double(posted.count)),
        ])
    }

    /// A click/move on the actual non-activating card window, through the app's
    /// event queue and local monitors. x/y start at the card's top-left, without
    /// the transparent shadow band. This proves its hit test, rather than
    /// invoking a tab-selection callback directly.
    private static func hoverCard(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        guard let card = services.hoverCards.debugInteractiveCard,
              let x = params["x"]?.doubleValue, let y = params["y"]?.doubleValue else {
            return .object(["error": .string("no interactive hover card, or missing x/y")])
        }
        let screen = CGPoint(x: card.frame.minX + x, y: card.frame.maxY - y)
        let base = card.window.convertPoint(fromScreen: screen)
        let topLeft = InputJournal.topLeftPoint(base, in: card.window, relativeTo: card.window)
        let action = params["action"]?.stringValue ?? "click"
        guard ["move", "click"].contains(action) else { return .object(["error": .string("pass action move or click")]) }
        let types: [NSEvent.EventType] = action == "move" ? [.mouseMoved] : [.leftMouseDown, .leftMouseUp]
        let events = types.compactMap { mouse($0, at: topLeft, in: card.window, flags: [], clicks: action == "move" ? 0 : 1) }
        guard events.count == types.count else { return .object(["error": .string("could not synthesize card events")]) }
        // Keep the coordinator's synthetic screen point authoritative. Walking
        // tracking areas here would send a row exit before the non-activating
        // card receives the move, which is unlike the real panel crossing.
        services.hoverCards.pointerMoved(to: screen)
        SyntheticInput.register(events)
        for event in events { NSApp.postEvent(event, atStart: false) }
        return .object(["posted": .number(Double(events.count)), "target": .string("hover-card")])
    }

    /// Top-left window-local point from `x`,`y` or the center of `pane`.
    private static func point(_ params: [String: JSONValue], controller: WindowController, window: NSWindow) -> NSPoint? {
        if let x = params["x"]?.doubleValue, let y = params["y"]?.doubleValue { return NSPoint(x: x, y: y) }
        if let row = params["row"]?.stringValue { return rowPoint(row, controller: controller, window: window) }
        if let divider = params["divider"]?.stringValue { return dividerPoint(divider, controller: controller, window: window) }
        guard let key = params["pane"]?.stringValue, let pane = controller.content?.paneController(key: key) else { return nil }
        let view: NSView = pane.view.content ?? pane.view
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return InputJournal.topLeftPoint(center, in: window, relativeTo: window)
    }

    /// `point` (top-left window points, the journal's) in `window`'s base coordinates (bottom-left).
    static func baseLocation(_ point: NSPoint, in window: NSWindow) -> NSPoint {
        let height = window.contentView?.bounds.height ?? window.frame.height
        return NSPoint(x: point.x, y: height - point.y)
    }

    /// The press, release and drag event types for `button`.
    static func eventTypes(button: String?) -> (down: NSEvent.EventType, up: NSEvent.EventType, dragged: NSEvent.EventType) {
        switch button {
        case "right": (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case "middle": (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        default: (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        }
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags,
                      clicks: Int) -> NSEvent? {
        guard let event = NSEvent.mouseEvent(
            with: type, location: baseLocation(point, in: window), modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: clicks, pressure: [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type) ? 0 : 1
        ) else { return nil }
        guard [.otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(type) else { return event }
        // NSEvent.mouseEvent leaves buttonNumber 0 on otherMouse events; the
        // middle button is 2, which the views that handle it check. AppKit
        // maps the copy back through the window server's frame for the window,
        // which for a window not on screen is not the window's own frame, so the
        // copy is moved by what that mapping got wrong (DebugMouseButtonTests).
        guard let cg = event.cgEvent?.copy() else { return nil }
        cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        return keepingWindowPoint(cg, event.locationInWindow)
    }

    /// `cg` as an NSEvent at window-local `base`: built once, then moved by the
    /// difference between `base` and the point AppKit mapped (global y grows down).
    static func keepingWindowPoint(_ cg: CGEvent, _ base: NSPoint) -> NSEvent? {
        guard let first = NSEvent(cgEvent: cg) else { return nil }
        let miss = NSPoint(x: base.x - first.locationInWindow.x, y: base.y - first.locationInWindow.y)
        guard miss != .zero else { return first }
        cg.location = CGPoint(x: cg.location.x + miss.x, y: cg.location.y - miss.y)
        return NSEvent(cgEvent: cg)
    }

    /// A pixel scroll at `point`, addressed to `window` like the window
    /// server addresses a real one.
    /// `phase` (`began`, `changed`, `ended`) makes it a trackpad gesture
    /// event: continuous (precise deltas) with that scroll phase (R99 swipes).
    /// `flags` are the modifier keys held (NSEvent's flag bits are CGEvent's).
    private static func scroll(at point: NSPoint, in window: NSWindow, dx: Double, dy: Double, phase: String? = nil,
                               flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        scroll(atBase: baseLocation(point, in: window), in: window, dx: dx, dy: dy, phase: phase, flags: flags)
    }

    /// ``scroll(at:in:dx:dy:phase:flags:)`` at `base`, a point in `window`'s base coordinates (a page
    /// window's, `scrollPage`).
    static func scroll(atBase base: NSPoint, in window: NSWindow, dx: Double, dy: Double, phase: String? = nil,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
        cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        if let phase, let value = ["began": 1, "changed": 2, "ended": 4][phase] {
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(value))
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        }
        let screen = window.convertPoint(toScreen: base)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        return NSEvent(cgEvent: cg)
    }

    static func modifiers(_ names: [JSONValue]) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for name in names {
            switch name.stringValue {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "alt": flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            default: break
            }
        }
        return flags
    }
}
#endif
