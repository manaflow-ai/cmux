public import AppKit
public import WebKit

/// Native input for a WebKit page: AppKit events handed to its web view, so the page sees trusted
/// events (`isTrusted === true`) and WebKit runs their default actions (Tab moves focus, a held
/// button drags, a wheel scrolls). Nothing is posted to the system event stream; the person's
/// pointer and keyboard focus never move. The browser host's driver (`WebKitDriver+Input`) and
/// the App's `browser.page.*` input share this path.
///
/// ```swift
/// let input = WebKitNativeInput(privateCalls: WebKitPrivateCalls())
/// try await input.mouse(.leftMouseDown, at: CGPoint(x: 40, y: 20), clickCount: 1, flags: [], in: webView)
/// ```
public struct WebKitNativeInput: Sendable {
    /// Why an input was not delivered.
    public enum Failure: Error, Hashable, Sendable {
        /// The web view is in no window: AppKit events need one.
        case noWindow
        /// AppKit could not make the event.
        case noEvent
    }

    /// The bounded waits on WebKit's private callbacks.
    public let privateCalls: WebKitPrivateCalls

    /// - Parameter privateCalls: the gate and bound for WebKit's private callbacks.
    public init(privateCalls: WebKitPrivateCalls) {
        self.privateCalls = privateCalls
    }

    /// One mouse event of `type` at `css` (CSS px from the viewport's top-left), then a wait until
    /// WebKit processed it. A right press does not show the native context menu
    /// (`agentRightMouseDown`). A move hovers without moving the pointer.
    ///
    /// - Parameters:
    ///   - type: a mouse event type (`MouseEventPlan.eventType(for:button:)` gives it).
    ///   - css: the point in viewport CSS pixels.
    ///   - clickCount: the click count of a press or release (at least 1).
    ///   - flags: the modifier keys held.
    ///   - webView: the page's web view.
    /// - Throws: ``Failure/noWindow`` when the web view is in no window, ``Failure/noEvent`` when
    ///   AppKit makes no event.
    @MainActor
    public func mouse(_ type: NSEvent.EventType, at css: CGPoint, clickCount: Int, flags: NSEvent.ModifierFlags,
                      in webView: WKWebView) async throws(Failure) {
        guard let window = webView.window else { throw .noWindow }
        let release = [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type)
        guard let made = NSEvent.mouseEvent(
            with: type, location: Self.windowPoint(webView, css: css), modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: type == .mouseMoved ? 0 : max(1, clickCount),
            pressure: release || type == .mouseMoved ? 0 : 1
        ), let event = Self.withButtonNumber(made) else { throw .noEvent }
        Self.deliver(event, to: webView)
        await privateCalls.afterPendingMouseEvents(webView)
    }

    /// A wheel event at `css` scrolling the page by (`deltaX`, `deltaY`) CSS px, then a wait until
    /// WebKit processed it.
    ///
    /// - Throws: ``Failure/noWindow`` when the web view is in no window, ``Failure/noEvent`` when
    ///   no event could be made.
    @MainActor
    public func wheel(at css: CGPoint, deltaX: Double, deltaY: Double, flags: NSEvent.ModifierFlags,
                      in webView: WKWebView) async throws(Failure) {
        guard let window = webView.window else { throw .noWindow }
        // WebKit drops a wheel that reaches a just-loaded page before its next presentation
        // update (about one in three on the test Macs); an occluded window presents too.
        await privateCalls.afterNextPresentationUpdate(webView)
        guard let event = Self.wheelEvent(window: window, location: Self.windowPoint(webView, css: css),
                                          deltaX: deltaX, deltaY: deltaY, flags: flags) else { throw .noEvent }
        webView.scrollWheel(with: event)
        await privateCalls.afterPendingMouseEvents(webView)
    }

    /// One key event: `down` is a key down (with the Cocoa editing command of a Command shortcut
    /// when `nativeCommand`), else a key up; a modifier key is a flags change. `upFlags` are the
    /// flags of a modifier key's release.
    ///
    /// - Throws: ``Failure/noEvent`` when AppKit makes no event.
    @MainActor
    public func key(_ stroke: KeyStroke, down: Bool, isARepeat: Bool = false, upFlags: NSEvent.ModifierFlags = [],
                    nativeCommand: Bool = true, in webView: WKWebView) throws(Failure) {
        let type: NSEvent.EventType = stroke.isModifier ? .flagsChanged : (down ? .keyDown : .keyUp)
        guard let event = NSEvent.keyEvent(
            with: type, location: .zero,
            modifierFlags: !down && stroke.isModifier ? upFlags : stroke.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: webView.window?.windowNumber ?? 0, context: nil,
            // An Option chord types no text, as with a CDP key event (macOS
            // would type its Option character, such as  for Option+Shift+K).
            characters: stroke.modifierFlags.contains(.option) && !stroke.isModifier ? "" : stroke.characters,
            charactersIgnoringModifiers: stroke.charactersIgnoringModifiers,
            isARepeat: isARepeat, keyCode: stroke.keyCode
        ) else { throw .noEvent }
        switch type {
        case .flagsChanged: webView.flagsChanged(with: event)
        case .keyDown:
            webView.keyDown(with: event)
            if nativeCommand, let command = stroke.editingCommand, webView.responds(to: NSSelectorFromString(command)) {
                // Command keys are menu equivalents in AppKit; the editing
                // command goes to the web view only, never up the responder
                // chain to the person's window (its undo manager).
                webView.perform(NSSelectorFromString(command), with: nil)
            }
        default: webView.keyUp(with: event)
        }
    }

    /// An IME-style commit of `text` into the page's focused element, through the web view's text
    /// input client. False when the web view takes no text input.
    @MainActor
    @discardableResult
    public func insertText(_ text: String, into webView: WKWebView) -> Bool {
        // WKWebView adopts NSTextInputClient at runtime only.
        guard let client = (webView as AnyObject) as? any NSTextInputClient else { return false }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    /// CSS pixels (viewport top-left) to the web view's window coordinates.
    @MainActor
    static func windowPoint(_ webView: WKWebView, css: CGPoint) -> NSPoint {
        let view = MouseEventPlan.viewPoint(css: css, scale: webView.pageZoom * webView.magnification,
                                            viewHeight: webView.bounds.height, flipped: webView.isFlipped)
        return webView.convert(view, to: nil)
    }

    @MainActor
    private static func deliver(_ event: NSEvent, to webView: WKWebView) {
        switch event.type {
        case .mouseMoved:
            // Hover without the pointer: WebKit SPI, else a plain move.
            // crash-allow: WebKit private selector, used only after responds(to:) confirms it exists.
            let simulate = NSSelectorFromString("_simulateMouseMove:")
            if webView.responds(to: simulate) { webView.perform(simulate, with: event) } else { webView.mouseMoved(with: event) }
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        case .leftMouseDragged: webView.mouseDragged(with: event)
        case .rightMouseDown: webView.agentRightMouseDown(event)
        case .rightMouseUp: webView.rightMouseUp(with: event)
        case .rightMouseDragged: webView.rightMouseDragged(with: event)
        case .otherMouseDown: webView.otherMouseDown(with: event)
        case .otherMouseUp: webView.otherMouseUp(with: event)
        case .otherMouseDragged: webView.otherMouseDragged(with: event)
        default: break
        }
    }

    /// A middle-button event with its button number (2): `NSEvent.mouseEvent`
    /// leaves it 0, and WebKit reports the DOM button from it. The number is
    /// set on the event's own Quartz form, which keeps its window and place.
    /// Other events are returned as they are.
    private static func withButtonNumber(_ event: NSEvent) -> NSEvent? {
        guard [.otherMouseDown, .otherMouseUp, .otherMouseDragged].contains(event.type) else { return event }
        guard let cg = event.cgEvent?.copy() else { return nil }
        cg.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
        return NSEvent(cgEvent: cg)
    }

    @MainActor
    private static func wheelEvent(window: NSWindow, location: NSPoint, deltaX: Double, deltaY: Double, flags: NSEvent.ModifierFlags) -> NSEvent? {
        // Page deltas scroll content; wheel deltas are the finger direction.
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(clamping: Int(-deltaY.rounded())), wheel2: Int32(clamping: Int(-deltaX.rounded())), wheel3: 0) else { return nil }
        // The Quartz location AppKit gives its own event at this window point.
        guard let place = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 0, pressure: 0)?.cgEvent?.location else { return nil }
        cg.location = place
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        // Without a window the event's location stays in screen space and
        // WebKit hit-tests the wheel at the wrong element.
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard var event = NSEvent(cgEvent: cg) else { return nil }
        // WebKit reads the wheel's place from `locationInWindow`, which AppKit derives from the
        // Quartz location (as a screen point when it leaves the event's window nil, as it often
        // does for a synthesized scroll). Move the Quartz location until it reads `location`
        // (Quartz y grows down, Cocoa y up).
        for _ in 0..<3 where event.locationInWindow != location {
            let read = event.locationInWindow
            cg.location = CGPoint(x: cg.location.x + location.x - read.x, y: cg.location.y - (location.y - read.y))
            guard let moved = NSEvent(cgEvent: cg) else { return nil }
            event = moved
        }
        return event
    }
}
