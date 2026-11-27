#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
import ObjectiveC

/// The remote Cocoa click probe (measurement builds, `CMUX_RC_CLICK_PROBE=1`; in-tree pages approach 4, MEASUREMENT
/// BRANCH ONLY). A wheel event handed to the view under a remote page reaches the page, but a press does not
/// (approaches/remote-cocoa rc-func-a2/b2: 9 of 9 presses unseen). This writes one `rc_click` line to the app's log at
/// each place a left press passes before the page's own `RenderWidgetHostViewCocoa` forwards it to the host (Chromium's
/// RenderWidgetHostNSViewHost.RouteOrProcessMouseEvent), so the first missing line names the hop that stops it:
///
/// - `dequeue`: the app took the press from its queue (a local monitor), with the window it names, whether that window
///   is key, takes mouse events and moved events, the app's activity, the source process of the press, every app window
///   over its point front to back (a panel that takes presses but not a scroll handed to the view shows here), and the
///   class chain the window's hit test returns at its point;
/// - `app_send`: `-[NSApplication sendEvent:]` of the app's class (cmux's interceptors run inside it);
/// - `window_send`: `-[NSWindow sendEvent:]` (a window subclass's call to super lands here too);
/// - `rwhv_accepts_first_mouse`: the page view's answer to AppKit's first-click question (an app that is not active
///   drops the press when it is no);
/// - `rwhv_mouse_down` / `rwhv_mouse_up`: the page view got the press, with what its own checks answer before it
///   forwards it: `shouldIgnoreMouseEvent:` (its hit test of the window), `hostIsDisconnected`, and whether an embedder
///   responder delegate may take it first;
/// - `page_view_mouse_down`: cmux's ``ChromiumHostPageView`` got it instead (in remote mode it forwards nothing).
@MainActor
enum ChromiumRemoteClickProbe {
    private static var installed = false

    nonisolated static var isEnabled: Bool { ProcessInfo.processInfo.environment["CMUX_RC_CLICK_PROBE"] == "1" }

    /// Installs the probe once (the first remote page); nothing without `CMUX_RC_CLICK_PROBE=1`.
    static func installIfEnabled() {
        guard isEnabled, !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            MainActor.assumeIsolated { log("dequeue", event, windowFacts(event) + hitFacts(event)) }
            return event
        }
        if let app = object_getClass(NSApp) {
            wrap(app, #selector(NSApplication.sendEvent(_:))) { _, event in
                if isPress(event) { log("app_send", event, "") }
            }
        }
        wrap(NSWindow.self, #selector(NSWindow.sendEvent(_:))) { window, event in
            guard isPress(event), let window = window as? NSWindow else { return }
            log("window_send", event, " to=\(name(window))#\(window.windowNumber) key=\(window.isKeyWindow ? 1 : 0)")
        }
        guard let rwhv = NSClassFromString("RenderWidgetHostViewCocoa") else { return log("no_rwhv_class", nil, "") }
        wrap(rwhv, #selector(NSView.mouseDown(with:))) { view, event in log("rwhv_mouse_down", event, viewFacts(view, event)) }
        wrap(rwhv, #selector(NSView.mouseUp(with:))) { _, event in log("rwhv_mouse_up", event, "") }
        wrapAnswer(rwhv, #selector(NSView.acceptsFirstMouse(for:))) { _, event, answer in
            log("rwhv_accepts_first_mouse", event, " answer=\(answer ? 1 : 0)")
        }
    }

    /// One line, with the press's time, type, point in its window and source process.
    nonisolated static func log(_ hop: String, _ event: NSEvent?, _ detail: String) {
        guard let event else { return NSLog("rc_click hop=%@%@", hop, detail) }
        let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        NSLog("rc_click hop=%@ t=%.4f type=%@ at=%.1f,%.1f win=%ld src_pid=%lld own_pid=%d%@", hop, event.timestamp,
              event.type == .leftMouseDown ? "down" : "up", event.locationInWindow.x, event.locationInWindow.y,
              event.windowNumber, source, getpid(), detail)
    }

    private nonisolated static func isPress(_ event: NSEvent) -> Bool { event.type == .leftMouseDown || event.type == .leftMouseUp }

    private nonisolated static func name(_ object: AnyObject) -> String { NSStringFromClass(type(of: object)) }

    /// The event's window and every app window over its point, front to back.
    private static func windowFacts(_ event: NSEvent) -> String {
        var line = " app_active=\(NSApp.isActive ? 1 : 0)"
        guard let window = event.window else { return line + " window=none" }
        line += " window=\(name(window))#\(window.windowNumber) key=\(window.isKeyWindow ? 1 : 0)"
        line += " main=\(window.isMainWindow ? 1 : 0) ignores=\(window.ignoresMouseEvents ? 1 : 0)"
        line += " moved=\(window.acceptsMouseMovedEvents ? 1 : 0) level=\(window.level.rawValue)"
        line += " first_responder=\(window.firstResponder.map(name) ?? "-")"
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        let over = NSApp.orderedWindows.filter { $0.isVisible && $0.frame.contains(screen) }
            .map { "\(name($0))#\($0.windowNumber):l\($0.level.rawValue):i\($0.ignoresMouseEvents ? 1 : 0):a\(String(format: "%.2f", $0.alphaValue))" }
        line += " over=[\(over.joined(separator: ","))]"
        let children = (window.childWindows ?? []).filter { $0.isVisible && $0.frame.contains(screen) }
            .map { "\(name($0))#\($0.windowNumber):i\($0.ignoresMouseEvents ? 1 : 0)" }
        return line + " children_over=[\(children.joined(separator: ","))]"
    }

    /// The class chain the window's hit test returns at the event's point (deepest first).
    private static func hitFacts(_ event: NSEvent) -> String {
        guard let frame = event.window?.contentView?.superview else { return " hit=none" }
        var chain: [String] = []
        var view = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
        while let current = view, chain.count < 10 {
            chain.append(name(current))
            view = current.superview
        }
        return " hit=[\(chain.joined(separator: ">"))]"
    }

    /// What the page view's own checks answer for `event` before it forwards it.
    private static func viewFacts(_ view: AnyObject, _ event: NSEvent) -> String {
        guard let view = view as? NSView, let cls = object_getClass(view) else { return "" }
        var line = " frame=\(NSStringFromRect(view.convert(view.bounds, to: nil))) in_window=\(view.window != nil ? 1 : 0)"
        line += " hidden=\(view.isHiddenOrHasHiddenAncestor ? 1 : 0)"
        typealias Ask = @convention(c) (AnyObject, Selector, NSEvent) -> Bool
        let ignore = NSSelectorFromString("shouldIgnoreMouseEvent:")
        if let method = class_getInstanceMethod(cls, ignore) {
            line += " ignores_event=\(unsafeBitCast(method_getImplementation(method), to: Ask.self)(view, ignore, event) ? 1 : 0)"
        }
        typealias Flag = @convention(c) (AnyObject, Selector) -> Bool
        let disconnected = NSSelectorFromString("hostIsDisconnected")
        if let method = class_getInstanceMethod(cls, disconnected) {
            line += " host_disconnected=\(unsafeBitCast(method_getImplementation(method), to: Flag.self)(view, disconnected) ? 1 : 0)"
        }
        if let ivar = class_getInstanceVariable(cls, "_responderDelegate") {
            line += " responder_delegate=\(object_getIvar(view, ivar).map { name($0 as AnyObject) } ?? "nil")"
        }
        if let frame = view.window?.contentView?.superview {
            let hit = frame.hitTest(frame.convert(event.locationInWindow, from: nil))
            line += " hit=\(hit.map(name) ?? "nil") hit_is_self=\(hit === view ? 1 : 0)"
            line += " hit_in_self=\(hit.map { $0.isDescendant(of: view) } == true ? 1 : 0)"
        }
        return line
    }

    /// Runs `before` and then the method `selector` had (the class's own, or the inherited one when it had none).
    private static func wrap(_ cls: AnyClass, _ selector: Selector, _ before: @escaping @MainActor (AnyObject, NSEvent) -> Void) {
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, NSEvent) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let block: @convention(block) (AnyObject, NSEvent) -> Void = { object, event in
            MainActor.assumeIsolated { before(object, event) }
            original(object, selector, event)
        }
        let replacement = imp_implementationWithBlock(block)
        if !class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
    }

    /// As ``wrap(_:_:_:)`` for a method that answers yes or no: `after` sees the answer.
    private static func wrapAnswer(_ cls: AnyClass, _ selector: Selector,
                                   _ after: @escaping @MainActor (AnyObject, NSEvent?, Bool) -> Void) {
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Call = @convention(c) (AnyObject, Selector, NSEvent?) -> Bool
        let original = unsafeBitCast(method_getImplementation(method), to: Call.self)
        let block: @convention(block) (AnyObject, NSEvent?) -> Bool = { object, event in
            let answer = original(object, selector, event)
            if let event, isPress(event) { MainActor.assumeIsolated { after(object, event, answer) } }
            return answer
        }
        let replacement = imp_implementationWithBlock(block)
        if !class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)) {
            method_setImplementation(method, replacement)
        }
    }
}
#endif
