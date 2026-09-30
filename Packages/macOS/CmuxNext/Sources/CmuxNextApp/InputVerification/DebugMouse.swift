#if DEBUG
import AppKit
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
/// `pane` (the center of that pane's content); `action`: `click` (default),
/// `double_click`, `down`, `up`, `drag` (to `to_x`,`to_y` in `steps`), or
/// `scroll` (`dx`,`dy` pixels); `button`: `left` (default), `right`;
/// `modifiers`: `cmd`, `shift`, `option`, `ctrl`.
enum DebugMouse {
    static func send(_ params: [String: JSONValue], services: AppServices) -> JSONValue {
        let windowID = params["window"]?.stringValue
        guard let controller = services.windows.controllers.first(where: { windowID == nil || $0.state.id == windowID }),
              let window = controller.window else { return .object(["error": .string("no window")]) }
        guard let point = point(params, controller: controller, window: window) else {
            return .object(["error": .string("pass x and y, or a pane shown in the window")])
        }
        let flags = modifiers(params["modifiers"]?.arrayValue ?? [])
        let right = params["button"]?.stringValue == "right"
        let (down, up, dragged): (NSEvent.EventType, NSEvent.EventType, NSEvent.EventType) =
            right ? (.rightMouseDown, .rightMouseUp, .rightMouseDragged) : (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
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
            let target = NSPoint(x: params["to_x"]?.doubleValue ?? point.x, y: params["to_y"]?.doubleValue ?? point.y)
            let steps = min(max(params["steps"]?.intValue ?? 12, 1), 200)
            events = [mouse(down, at: point, in: window, flags: flags, clicks: 1)]
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let at = NSPoint(x: point.x + (target.x - point.x) * t, y: point.y + (target.y - point.y) * t)
                events.append(mouse(dragged, at: at, in: window, flags: flags, clicks: 1))
            }
            events.append(mouse(up, at: target, in: window, flags: flags, clicks: 1))
        case "scroll":
            events = [scroll(at: point, in: window, dx: params["dx"]?.doubleValue ?? 0, dy: params["dy"]?.doubleValue ?? 0)]
        default:
            return .object(["error": .string("unknown action \(action)")])
        }
        let posted = events.compactMap { $0 }
        guard posted.count == events.count else { return .object(["error": .string("could not synthesize events")]) }
        for event in posted { NSApp.postEvent(event, atStart: false) }
        return .object([
            "window": .string(controller.state.id),
            "x": .number(point.x), "y": .number(point.y),
            "posted": .number(Double(posted.count)),
        ])
    }

    /// Top-left window-local point from `x`,`y` or the center of `pane`.
    private static func point(_ params: [String: JSONValue], controller: WindowController, window: NSWindow) -> NSPoint? {
        if let x = params["x"]?.doubleValue, let y = params["y"]?.doubleValue { return NSPoint(x: x, y: y) }
        guard let key = params["pane"]?.stringValue, let pane = controller.content?.paneController(key: key) else { return nil }
        let view: NSView = pane.view.content ?? pane.view
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return InputJournal.topLeftPoint(center, in: window, relativeTo: window)
    }

    private static func baseLocation(_ point: NSPoint, in window: NSWindow) -> NSPoint {
        let height = window.contentView?.bounds.height ?? window.frame.height
        return NSPoint(x: point.x, y: height - point.y)
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, flags: NSEvent.ModifierFlags,
                              clicks: Int) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: baseLocation(point, in: window), modifierFlags: flags,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
    }

    /// A pixel scroll at `point`, addressed to `window` like the window
    /// server addresses a real one.
    private static func scroll(at point: NSPoint, in window: NSWindow, dx: Double, dy: Double) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
        let screen = window.convertPoint(toScreen: baseLocation(point, in: window))
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
