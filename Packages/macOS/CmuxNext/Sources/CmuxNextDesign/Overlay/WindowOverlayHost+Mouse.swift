public import AppKit
import CmuxNextInput
import CmuxNextWakeups

extension WindowOverlayHost {
    // MARK: Mouse

    /// The panel takes the mouse only where an interactive overlay is. The
    /// window server picks a window before any app code sees a click, so the
    /// panel switches on mouse moves (and on every present, layout and
    /// dismiss) for the point under the pointer. In the window's top layer
    /// the layer's hit test picks each click's view (``OverlayTopLayerView``).
    func updateMouseRouting() {
        if isAppHost {
            panel.ignoresMouseEvents = handles.isEmpty
            return
        }
        guard usesPanel else { return updateTopLayerClickRouting() }
        let regions = interactiveRegions()
        guard !regions.isEmpty || showsAgentCursorTags else {
            panel.ignoresMouseEvents = true
            mouseRouting = nil
            return
        }
        routeMouse(at: pointerLocation())
        guard mouseRouting == nil, let tap = requiredInputTap(inputTap, owner: "WindowOverlayHost.mouseRouting") else { return }
        // An observer of the tap: it never stops the event (a move, a drag, a click or a tracking-area
        // edge of any window). The parent window takes no mouse moves, so over it the pointer sends
        // only tracking-area enters and exits (a page window's too); they route the mouse as a move does.
        // A panel off screen has nothing to route.
        mouseRouting = tap.subscribe(class: [.pointerMove, .drag, .button, .tracking],
                                     while: { [weak self] in self?.panel.isVisible == true }) { [weak self] event in
            self?.routingEvent(event)
        }
    }

    /// The window's top layer needs no pointer routing: an observer of clicks only, while a modal shows,
    /// so a click into a tab dialog gives it the keyboard back (``clickDidLand(in:at:)``).
    private func updateTopLayerClickRouting() {
        guard handles.contains(where: { $0.options.isModal }) else {
            mouseRouting = nil
            return
        }
        guard mouseRouting == nil, let tap = requiredInputTap(inputTap, owner: "WindowOverlayHost.topLayerClicks") else { return }
        mouseRouting = tap.subscribe(class: .button, while: { [weak self] in self?.isTopLayerInWindow == true }) { [weak self] event in
            self?.routingEvent(event)
        }
    }

    /// Whether `type` is a hover event ``routeCoveredHover(_:)`` may keep from the views below the top layer.
    public nonisolated static func isCoverableHover(_ type: NSEvent.EventType) -> Bool {
        type == .mouseMoved || type == .mouseEntered || type == .cursorUpdate
    }

    /// A hover event of the window at a point its top layer covers (an interactive overlay, a modal's region,
    /// a scrim) reaches only the top layer: true when it was handled here and the window must not send it on.
    /// AppKit sends tracking-area events by geometry, under any view above; Chromium sends each pointer event
    /// to the one target its hit test picks (`content/browser/renderer_host/render_widget_host_input_event_router.cc`),
    /// so nothing below a dialog or a popover hovers, shows its tooltip or sets its cursor, as under the panel.
    /// A move goes to the top layer's own tracking areas there; an enter or cursor update of an area below is
    /// dropped (the arrow shows). Exits always pass, so a hover that began before the overlay can end.
    public func routeCoveredHover(_ event: NSEvent) -> Bool { // perf-hot: 5us main-turn (every hover event of a window with a top layer)
        guard Self.isCoverableHover(event.type), isTopLayerInWindow, let window, event.window === window else { return false }
        let point = topLayer.convert(event.locationInWindow, from: nil)
        guard acceptsMouse(at: point) else { return false }
        var areas: [(view: NSView, area: NSTrackingArea)] = []
        Self.collectTrackingAreas(in: topLayer, into: &areas)
        if event.type == .mouseMoved {
            for (view, area) in areas where area.options.contains(.mouseMoved) {
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                guard rect.contains(view.convert(event.locationInWindow, from: nil)) else { continue }
                (area.owner as? NSResponder)?.mouseMoved(with: event)
            }
            return true
        }
        // An area of the top layer gets its own enter and cursor update; any other (a cursor rect has none) is below.
        if let area = event.trackingArea, areas.contains(where: { $0.area === area }) { return false }
        if event.type == .cursorUpdate { (topLayer.hitTest(topLayer.convert(point, to: topLayer.superview)) ?? topLayer).cursorUpdate(with: event) }
        return true
    }

    /// Every tracking area of the shown views of `view`'s tree, with the view it was added to.
    private static func collectTrackingAreas(in view: NSView, into areas: inout [(view: NSView, area: NSTrackingArea)]) {
        areas += view.trackingAreas.map { (view: view, area: $0) }
        for child in view.subviews where !child.isHidden { collectTrackingAreas(in: child, into: &areas) }
    }

    /// One pointer event seen by `mouseRouting`: a click may give the overlay the keyboard; a move, a
    /// drag or a tracking-area enter or exit routes the mouse (button ups pass by).
    func routingEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let inOverlays = event.window != nil && event.window === overlayWindow
            clickDidLand(in: event.window, at: inOverlays ? topLayer.convert(event.locationInWindow, from: nil) : .zero)
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseEntered, .mouseExited:
            routePointerEvent(event)
        default:
            break
        }
    }

    /// A move, a drag or a tracking-area edge routes the mouse. The click routing follows every event in
    /// its own turn: the window server reads `ignoresMouseEvents` to pick the window of the next click
    /// before any app code sees that click, and the test is one rect check on the cached regions.
    /// Only the agent cursor tag hover waits for the frame (``hoverFrames``, feature `pointerFrameHover`):
    /// the first move of a frame interval hovers in its own turn, the rest once at the frame, at the
    /// pointer then. Chromium splits the same way: the browser hit-tests each event for its target
    /// (`content/browser/renderer_host/render_widget_host_input_event_router.cc`), and only the
    /// renderer's main-thread dispatch is aligned to rAF
    /// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`). A tracking-area
    /// edge is discrete: it lands the waiting tag hover now.
    func routePointerEvent(_ event: NSEvent) { // perf-hot: 2us main-turn (every pointer event while an overlay takes clicks)
        // The tap and the panel's own `sendEvent` both hand over a move on the panel: route it once.
        guard event !== lastRoutingEvent else { return }
        lastRoutingEvent = event
        let point = panelPoint(of: pointerLocation())
        routeClicks(at: point)
        // No tag shows in the panel: nothing to hover.
        guard let carrierWindow = agentCursorCarrier?.window, carrierWindow === madePanel else { return }
        if let moves = tagHoverConsumer(), moves.post(event) { return }
        hoverAgentCursorTagNow(at: point)
    }

    /// The panel takes the mouse at `point` (panel coordinates) only over an interactive overlay or a tag.
    func routeClicks(at point: NSPoint) {
        let accepts = acceptsMouse(at: point)
        if panel.ignoresMouseEvents == accepts { panel.ignoresMouseEvents = !accepts }
    }

    /// The tag hover at `point` (panel coordinates) now: the waiting moves land, at the pointer now, or it hovers.
    func hoverAgentCursorTagNow(at point: NSPoint) {
        if let tagHoverMoves, tagHoverMoves.hasPending {
            tagHoverMoves.flush()
        } else {
            hoverAgentCursorTag(at: point)
        }
    }

    /// The tag hover's consumer on the parent window's coalescer while the tap routes the mouse; nil
    /// without frames, a window or the tap's observer (each move hovers then).
    func tagHoverConsumer() -> PointerFrameConsumer? {
        if let tagHoverMoves { return tagHoverMoves }
        guard mouseRouting != nil, let hoverFrames, let window else { return nil }
        let consumer = hoverFrames.coalescer(for: window).consumer(owner: "WindowOverlayHost.tagHover") { [weak self] _ in
            guard let self, mouseRouting != nil else { return }
            hoverAgentCursorTag(at: panelPoint(of: pointerLocation()))
        }
        tagHoverMoves = consumer
        return consumer
    }

    /// Drops the tag hover's waiting moves and its consumer (the routing stopped or its frames changed).
    func stopTagHoverMoves() {
        tagHoverMoves?.cancel()
        tagHoverMoves = nil
    }

    /// Routes clicks and hovers the tag at the pointer, `screenPoint` (a present, a layout, a dismiss).
    func routeMouse(at screenPoint: NSPoint) {
        let point = panelPoint(of: screenPoint)
        routeClicks(at: point)
        hoverAgentCursorTagNow(at: point)
    }

    /// `screenPoint` in the panel's coordinates (screen coordinates while the panel has no frame).
    func panelPoint(of screenPoint: NSPoint) -> NSPoint {
        panel.frame.isEmpty ? screenPoint : panel.convertPoint(fromScreen: screenPoint)
    }

    /// A tab dialog takes the keyboard when a click lands on it; a click
    /// anywhere else leaves the keyboard where that click puts it.
    func wantsKey(forClickIn clicked: NSWindow?, at point: NSPoint) -> Bool {
        guard let clicked, clicked === overlayWindow else { return false }
        let bounds = topLayer.overlayContainer.bounds
        return handles.contains { $0.options.isModal && ($0.options.modalRegion ?? bounds).contains(point) }
    }

    func clickDidLand(in clicked: NSWindow?, at point: NSPoint) {
        guard wantsKey(forClickIn: clicked, at: point), let overlayWindow,
              let top = handles.last(where: { $0.options.isModal }) else { return }
        let first = Self.keyViews(in: top.content).first ?? top.content
        guard usesPanel else {
            // In the window's top layer: the dialog takes the window's keyboard back unless it has it. A text
            // field the click lands on takes it from the first control after this observer.
            if !((overlayWindow.firstResponder as? NSView)?.isDescendant(of: topLayer) ?? false) {
                overlayWindow.makeFirstResponder(first)
            }
            return
        }
        guard !overlayWindow.isKeyWindow else { return }
        overlayWindow.makeKey()
        if !(overlayWindow.firstResponder is NSText) { overlayWindow.makeFirstResponder(first) }
    }

    /// A mouse event reached the panel. A move updates the routing; a click
    /// outside every interactive region (the panel had not let go yet) goes
    /// on to the parent window, and the panel lets go of the mouse.
    func panelMouseEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A new click: an earlier forwarded click whose up never reached
            // the panel (a drag session or a menu loop took it) is over.
            forwardTarget = nil
            let point = event.locationInWindow
            guard !isAppHost, !acceptsMouse(at: point), let window else { return false }
            panel.ignoresMouseEvents = true
            // The rest of this click (drags and the up of the same button)
            // still comes to the panel, which got the down: it goes to the same target.
            forwardTarget = forwardingTarget(for: panel.convertPoint(toScreen: point), in: window)
            forwardButton = Self.button(of: event)
            forward(event)
            return true
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard forwardTarget != nil, Self.button(of: event) == forwardButton else {
                if forwardTarget == nil { routePointerEvent(event) }
                return false
            }
            forward(event)
            return true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            guard forwardTarget != nil, Self.button(of: event) == forwardButton else { return false }
            forward(event)
            forwardTarget = nil
            return true
        case .mouseMoved, .mouseEntered, .mouseExited:
            routePointerEvent(event)
            return false
        default:
            return false
        }
    }

    /// The mouse button of an event: from its type for left and right
    /// (`buttonNumber` is not set on every event), else `buttonNumber`.
    static func button(of event: NSEvent) -> Int {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: 0
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: 1
        default: max(2, event.buttonNumber)
        }
    }

    /// The window under a click outside every interactive region: the
    /// window itself over an occluder (the sidebar, where page frames run
    /// under it), else the frontmost page window there, else the window.
    func forwardingTarget(for screenPoint: NSPoint, in window: NSWindow) -> NSWindow {
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        if occluderRects.contains(where: { $0.contains(windowPoint) }) { return window }
        return Self.frontPageWindow(at: screenPoint, in: window) ?? window
    }

    /// The frontmost visible page window (``isPageWindow(_:on:)``) of `window` under `screenPoint`, as the window
    /// server picks the window a pointer event goes to; nil over no page. With pages in the view tree
    /// (``PageSurface/views``) only a content panel can be one: the window itself takes the rest.
    ///
    /// - Parameters:
    ///   - screenPoint: A point in screen coordinates.
    ///   - window: The window whose child page windows are searched.
    /// - Returns: The page window under the point, or nil.
    public static func frontPageWindow(at screenPoint: NSPoint, in window: NSWindow) -> NSWindow? {
        let surface = PageSurface.of(window)
        let pages = (window.childWindows ?? []).filter { isPageWindow($0, on: surface) && $0.isVisible && $0.frame.contains(screenPoint) }
        guard pages.count > 1 else { return pages.first }
        // Front to back (child order is add order, not z-order).
        let order = (NSWindow.windowNumbers(options: []) ?? []).map(\.intValue)
        return pages.min { (order.firstIndex(of: $0.windowNumber) ?? .max) < (order.firstIndex(of: $1.windowNumber) ?? .max) }
    }

    /// Sends `event` to `forwardTarget` in that window's coordinates. It runs
    /// inside the panel's sendEvent, so NSApp.currentEvent is still the
    /// panel's event and the input tap does not see the forwarded copy.
    func forward(_ event: NSEvent) {
        guard let target = forwardTarget else { return }
        let screen = panel.convertPoint(toScreen: event.locationInWindow)
        // A copy of the real event keeps its drag deltas (pointer lock, page
        // drags use them); only the window and location change.
        if let copy = event.cgEvent?.copy() {
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowNumber))
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowNumber))
            if let forwarded = NSEvent(cgEvent: copy) {
                return target.sendEvent(Self.relocated(forwarded, to: target, screen: screen) ?? forwarded)
            }
        }
        if let forwarded = Self.relocated(event, to: target, screen: screen) { target.sendEvent(forwarded) }
    }

    /// `event` addressed to `target` at the screen point (deltas are lost: a fallback only).
    static func relocated(_ event: NSEvent, to target: NSWindow, screen: NSPoint) -> NSEvent? {
        guard event.window !== target else { return event }
        return NSEvent.mouseEvent(with: event.type, location: target.convertPoint(fromScreen: screen),
                                  modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                  windowNumber: target.windowNumber, context: nil, eventNumber: event.eventNumber,
                                  clickCount: event.clickCount, pressure: event.pressure)
    }
}
