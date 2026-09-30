import AppKit
import CmuxBrowser
import WebKit

/// Builds the AppKit events the REPL driver sends to WebKit.
@MainActor
enum BrowserReplNativeInput {
    private static var eventNumber = 0

    /// CSS pixels (viewport top-left origin) to the web view's window coordinates.
    static func windowPoint(webView: WKWebView, cssPoint: CGPoint) -> NSPoint {
        let scale = webView.pageZoom * webView.magnification
        let viewPoint = BrowserReplCoordinateSpace.viewPoint(
            cssPoint: cssPoint,
            cssPerPoint: scale > 0 ? 1 / scale : 1,
            viewIsFlipped: webView.isFlipped,
            viewHeight: webView.bounds.height
        )
        return webView.convert(viewPoint, to: nil)
    }

    static func mouseEvent(
        type: NSEvent.EventType,
        button: BrowserReplMouseButton,
        webView: WKWebView,
        window: NSWindow,
        cssPoint: CGPoint,
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        let location = windowPoint(webView: webView, cssPoint: cssPoint)
        eventNumber += 1
        if button == .middle, type != .mouseMoved {
            return otherButtonEvent(type: type, window: window, location: location, clickCount: clickCount, modifierFlags: modifierFlags)
        }
        let isPress = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            || type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged
        return NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: type == .mouseMoved ? 0 : max(1, clickCount),
            pressure: isPress ? 1 : 0
        )
    }

    /// Middle-button events need a button number, which only a CGEvent carries.
    private static func otherButtonEvent(
        type: NSEvent.EventType,
        window: NSWindow,
        location: NSPoint,
        clickCount: Int,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        let cgType: CGEventType
        switch type {
        case .otherMouseDown: cgType = .otherMouseDown
        case .otherMouseUp: cgType = .otherMouseUp
        default: cgType = .otherMouseDragged
        }
        return aligned(window: window, location: location) { point in
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: cgType,
                mouseCursorPosition: point,
                mouseButton: .center
            ) else { return nil }
            event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
            event.flags = cgFlags(modifierFlags)
            stampWindow(event, window: window)
            return NSEvent(cgEvent: event)
        }
    }

    static func wheelEvent(
        webView: WKWebView,
        window: NSWindow,
        cssPoint: CGPoint,
        deltaX: Double,
        deltaY: Double,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        let location = windowPoint(webView: webView, cssPoint: cssPoint)
        // Page-space deltas scroll content down/right; wheel deltas are the
        // finger direction, so they flip sign.
        return aligned(window: window, location: location) { point in
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(clamping: Int(-deltaY.rounded())),
                wheel2: Int32(clamping: Int(-deltaX.rounded())),
                wheel3: 0
            ) else { return nil }
            event.location = point
            event.flags = cgFlags(modifierFlags)
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            stampWindow(event, window: window)
            return NSEvent(cgEvent: event)
        }
    }

    /// Builds a CGEvent-backed NSEvent whose `locationInWindow` is `location`.
    /// AppKit derives that from the event's global position and, depending on
    /// the event, its window; one correction pass removes the difference.
    private static func aligned(
        window: NSWindow,
        location: NSPoint,
        make: (CGPoint) -> NSEvent?
    ) -> NSEvent? {
        var global = globalPoint(window: window, location: location)
        guard let first = make(global) else { return nil }
        let dx = location.x - first.locationInWindow.x
        let dy = location.y - first.locationInWindow.y
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return first }
        global.x += dx
        global.y -= dy
        return make(global) ?? first
    }

    /// Commits `text` through the text input client, as an IME would.
    static func insertText(_ text: String, into webView: WKWebView) {
        guard let client = webView as? any NSTextInputClient else { return }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Waits until WebKit has dispatched every queued mouse event to the page.
    static func waitForPendingMouseEvents(_ webView: WKWebView) async {
        let selector = NSSelectorFromString("_doAfterProcessingAllPendingMouseEvents:")
        guard webView.responds(to: selector) else {
            await roundTrip(webView)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            typealias Action = @convention(block) () -> Void
            typealias Function = @convention(c) (AnyObject, Selector, Action) -> Void
            let function = unsafeBitCast(webView.method(for: selector), to: Function.self)
            let action: Action = { continuation.resume() }
            function(webView, selector, action)
        }
    }

    /// Waits until the web process has applied WebKit's pending activity
    /// state (window key, visibility, first-responder focus). WebKit runs the
    /// block at once when no update is scheduled. Without the SPI, one
    /// JavaScript round trip, which orders after an update already sent.
    static func afterActivityStateUpdate(_ webView: WKWebView) async {
        let selector = NSSelectorFromString("_doAfterActivityStateUpdate:")
        guard webView.responds(to: selector) else {
            await roundTrip(webView)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            typealias Action = @convention(block) () -> Void
            typealias Function = @convention(c) (AnyObject, Selector, Action) -> Void
            let function = unsafeBitCast(webView.method(for: selector), to: Function.self)
            let action: Action = { continuation.resume() }
            function(webView, selector, action)
        }
    }

    /// One JavaScript round trip: WebKit answers after the web process has
    /// handled every message sent before it on the same connection.
    static func roundTrip(_ webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(
            "return 0;",
            arguments: [:],
            in: nil,
            contentWorld: BrowserReplAgentWorld.world
        )
    }

    private static func globalPoint(window: NSWindow, location: NSPoint) -> CGPoint {
        let screenPoint = window.convertPoint(toScreen: location)
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screenPoint.y
        return CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
    }

    private static func stampWindow(_ event: CGEvent, window: NSWindow) {
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
    }

    private static func cgFlags(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        return result
    }
}
