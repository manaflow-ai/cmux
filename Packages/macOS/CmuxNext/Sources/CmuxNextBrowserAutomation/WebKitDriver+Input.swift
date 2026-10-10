import AppKit
import CmuxNextBrowser
import Foundation
import WebKit

/// Native input: AppKit events handed to the tab's web view, so the page
/// sees trusted events (`isTrusted === true`). Nothing is posted to the
/// system event stream; the user's pointer and keyboard focus never move.
extension WebKitDriver {
    func inputMouse(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, session) = try target(params)
        let webView = tab.webView
        guard let window = webView.window else {
            throw DriverError(.unsupported, "input.mouse: the tab is not in a window (hidden tabs need the off-screen render window)")
        }
        let type = try params.string("type")
        let css = CGPoint(x: try params.number("x"), y: try params.number("y"))
        let flags = KeyStroke.flags(named: try params.strings("modifiers"))
        let location = windowPoint(webView, css: css)
        if type == "wheel" {
            let dx = try params.optionalNumber("deltaX") ?? 0
            let dy = try params.optionalNumber("deltaY") ?? 0
            guard let event = Self.wheelEvent(window: window, location: location, deltaX: dx, deltaY: dy, flags: flags) else {
                throw DriverError(.invalid, "input.mouse: could not create a wheel event")
            }
            webView.scrollWheel(with: event)
            await afterPendingMouseEvents(webView)
            return .null
        }
        // A right-click's native menu is not shown (`agentRightMouseDown`).
        let button = MouseEventPlan.Button(rawValue: try params.optionalString("button") ?? "left") ?? .left
        guard let eventType = session.mouse.eventType(for: type, button: button) else {
            throw DriverError(.invalid, "input.mouse: type: expected move, down, up or wheel, got \(type)")
        }
        session.mouseLocation = css
        let clickCount = Int(try params.optionalNumber("clickCount") ?? 1)
        guard let made = NSEvent.mouseEvent(
            with: eventType, location: location, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: eventType == .mouseMoved ? 0 : max(1, clickCount),
            pressure: type == "up" || eventType == .mouseMoved ? 0 : 1
        ), let event = Self.withButtonNumber(made) else {
            throw DriverError(.invalid, "input.mouse: could not create a mouse event")
        }
        deliver(event, to: webView)
        await afterPendingMouseEvents(webView)
        return .null
    }

    func inputKey(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, _) = try target(params)
        let webView = tab.webView
        let type = try params.string("type")
        let key = try params.string("key")
        let text = try params.optionalString("text")
        guard let stroke = KeyStroke.resolve(key: key, code: try params.optionalString("code") ?? "", text: text,
                                             modifiers: try params.strings("modifiers")) else {
            // No virtual key: the text goes through the text input client.
            if type == "down", let text, !text.isEmpty { insertText(text, into: webView) }
            return .null
        }
        let window = webView.window
        let eventType: NSEvent.EventType = stroke.isModifier ? .flagsChanged : (type == "down" ? .keyDown : .keyUp)
        guard let event = NSEvent.keyEvent(
            with: eventType, location: .zero,
            modifierFlags: type == "up" && stroke.isModifier ? KeyStroke.flags(named: try params.strings("modifiers")) : stroke.modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: stroke.characters, charactersIgnoringModifiers: stroke.charactersIgnoringModifiers,
            isARepeat: try params.bool("autoRepeat"), keyCode: stroke.keyCode
        ) else {
            throw DriverError(.invalid, "input.key: could not create a key event for \(key)")
        }
        switch eventType {
        case .flagsChanged: webView.flagsChanged(with: event)
        case .keyDown:
            webView.keyDown(with: event)
            if let command = stroke.editingCommand, webView.responds(to: NSSelectorFromString(command)) {
                // Command keys are menu equivalents in AppKit; the editing
                // command goes to the web view only, never up the responder
                // chain to the user's window (its undo manager).
                webView.perform(NSSelectorFromString(command), with: nil)
            }
        default: webView.keyUp(with: event)
        }
        return .null
    }

    /// An IME-style commit into the focused element. Rich-text editors that
    /// start an edit only on a composition get marked text first (UNVERIFIED
    /// here; #15570 does it after a presentation update).
    func inputInsertText(_ params: DriverParams) async throws(DriverError) -> DriverJSON {
        let (tab, _) = try target(params)
        let text = try params.string("text")
        guard insertText(text, into: tab.webView) else {
            throw DriverError(.unsupported, "input.insertText: the web view takes no text input")
        }
        return .null
    }

    /// WKWebView adopts NSTextInputClient at runtime only.
    @discardableResult
    private func insertText(_ text: String, into webView: WKWebView) -> Bool {
        guard let client = (webView as AnyObject) as? any NSTextInputClient else { return false }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    /// CSS pixels (viewport top-left) to the web view's window coordinates.
    private func windowPoint(_ webView: WKWebView, css: CGPoint) -> NSPoint {
        let view = MouseEventPlan.viewPoint(css: css, scale: webView.pageZoom * webView.magnification,
                                            viewHeight: webView.bounds.height, flipped: webView.isFlipped)
        return webView.convert(view, to: nil)
    }

    private func deliver(_ event: NSEvent, to webView: WKWebView) {
        switch event.type {
        case .mouseMoved:
            // Hover without the pointer: WebKit SPI, else a plain move.
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

    private typealias AfterIMP = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void

    /// Waits until WebKit processed the mouse events sent so far (SPI
    /// `_doAfterProcessingAllPendingMouseEvents:`); returns at once without it.
    private func afterPendingMouseEvents(_ webView: WKWebView) async {
        let selector = NSSelectorFromString("_doAfterProcessingAllPendingMouseEvents:")
        guard webView.responds(to: selector) else { return }
        let imp = unsafeBitCast(webView.method(for: selector), to: AfterIMP.self)
        // Bounded like every WebKit block wait: a page whose web process
        // never answers (not loaded yet, suspended) must not hang the call.
        _ = await privateCalls.awaitCallback { done in
            imp(webView, selector) { done() }
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
        guard let event = NSEvent(cgEvent: cg) else { return nil }
        if event.window === window { return event }
        // AppKit often leaves a synthesized scroll's window nil (the app's
        // debug.mouse scroll meets the same). Its locationInWindow is then
        // the Quartz point read as a Cocoa screen point, which WebKit takes
        // as the window point: place the event so that it reads `location`.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: location.x, y: primaryHeight - location.y)
        return NSEvent(cgEvent: cg)
    }
}
