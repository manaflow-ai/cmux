import AppKit
import CmuxBrowser
import UniformTypeIdentifiers
import WebKit

/// Builds the AppKit events the REPL driver sends to WebKit.
@MainActor
enum BrowserReplNativeInput {
    private static var eventNumber = 0

    /// CSS pixels (viewport top-left origin) to the web view's window coordinates.
    static func windowPoint(webView: WKWebView, cssPoint: CGPoint) -> NSPoint {
        let scale = webView.pageZoom * webView.magnification
        let viewPoint = cssPoint.browserReplViewPoint(
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
        delta: BrowserReplWheelDelta,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        let location = windowPoint(webView: webView, cssPoint: cssPoint)
        return aligned(window: window, location: location) { point in
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: delta.vertical,
                wheel2: delta.horizontal,
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

    /// Commits `text` through the text input client the way an input method
    /// does: as marked text that is then confirmed, so the page sees
    /// `compositionstart`, `beforeinput`/`input` and `compositionend`, all
    /// trusted. Editors that start an edit only on a keydown or a composition
    /// (Google Sheets' cell editor in WebKit) take the text; a plain
    /// `insertText:` with no composition reaches the DOM but not their model.
    ///
    /// Only a rich-text editor (a `contenteditable` element) gets the
    /// composition. A text field gets a plain insert, which fires one `input`
    /// event as Chrome's `Input.insertText` does; a composition there would
    /// fire three. Text also inserts directly when it holds a line break or a
    /// tab (editing commands, not composed text), when focus is in a frame
    /// the agent cannot inspect, or when WebKit's editor state, which gates
    /// marked text, is not current within `stateTimeout`. The sequence is
    /// `BrowserReplTextCommitTarget.commit(_:checkTarget:)`; `checkTarget` throws to refuse the focused
    /// element, and then nothing is inserted.
    ///
    /// `checkTarget` gets the web view the text goes to, and judges that
    /// one; `isCurrent` says whether the tab still shows it, asked on the
    /// commit's turn after the check (a tab that replaced its web view
    /// meanwhile gets nothing, `stale`).
    static func insertText(
        _ text: String,
        into webView: WKWebView,
        stateTimeout: Duration = .milliseconds(500),
        isCurrent: @escaping @MainActor () -> Bool = { true },
        checkTarget: @MainActor @Sendable (WKWebView) async throws -> Void = { _ in }
    ) async throws {
        guard let client = webView as? any NSTextInputClient else { return }
        let target = WebViewTextTarget(webView: webView, client: client, stateTimeout: stateTimeout, isCurrent: isCurrent)
        try await target.commit(text) { try await checkTarget(webView) }
    }

    /// A web view's text input client as `commit(_:checkTarget:)` drives it.
    @MainActor
    private final class WebViewTextTarget: BrowserReplTextCommitTarget {
        let webView: WKWebView
        let client: any NSTextInputClient
        let stateTimeout: Duration
        private let isCurrentWebView: @MainActor () -> Bool
        private let noReplacement = NSRange(location: NSNotFound, length: 0)

        init(webView: WKWebView, client: any NSTextInputClient, stateTimeout: Duration, isCurrent: @escaping @MainActor () -> Bool) {
            self.webView = webView
            self.client = client
            self.stateTimeout = stateTimeout
            isCurrentWebView = isCurrent
        }

        var hasMarkedText: Bool { client.hasMarkedText() }

        var isCurrent: Bool { isCurrentWebView() }

        func prepareComposition() async -> Bool {
            guard await BrowserReplNativeInput.focusIsRichTextEditor(webView) else { return false }
            return await BrowserReplNativeInput.afterPresentationUpdate(webView, timeout: stateTimeout)
        }

        func setMarkedText(_ text: String) {
            let length = (text as NSString).length
            client.setMarkedText(
                text,
                selectedRange: NSRange(location: length, length: 0),
                replacementRange: noReplacement
            )
        }

        func insertText(_ text: String) {
            client.insertText(text, replacementRange: noReplacement)
        }
    }

    /// Whether the focused element, followed through same-origin frames and
    /// shadow roots, is a `contenteditable` editor (not a form field) in a
    /// frame the agent world can read.
    fileprivate static func focusIsRichTextEditor(_ webView: WKWebView) async -> Bool {
        let result = try? await webView.browserReplCallAsyncJavaScript(
            """
            let doc = document;
            let el = doc.activeElement;
            for (let depth = 0; el && depth < 32; depth++) {
              if (el.tagName === "IFRAME" || el.tagName === "FRAME") {
                let inner = null;
                try { inner = el.contentDocument; } catch (e) { inner = null; }
                if (!inner) return false;
                doc = inner;
                el = doc.activeElement;
              } else if (el.shadowRoot && el.shadowRoot.activeElement) {
                el = el.shadowRoot.activeElement;
              } else {
                break;
              }
            }
            if (!el || el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) return false;
            return el.isContentEditable === true;
            """,
            arguments: [:],
            in: nil,
            contentWorld: BrowserReplAgentWorld.world,
            userGesture: false
        )
        return (result as? Bool) ?? false
    }

    /// Waits until the web process has committed its next presentation
    /// update, which carries the editor state, or `timeout` passes. Returns
    /// whether the update arrived. Without the SPI, one JavaScript round trip.
    static func afterPresentationUpdate(_ webView: WKWebView, timeout: Duration) async -> Bool {
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        guard webView.responds(to: selector) else {
            await roundTrip(webView)
            return true
        }
        let gate = BrowserReplOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            gate.continuation = continuation
            typealias Action = @convention(block) () -> Void
            typealias Function = @convention(c) (AnyObject, Selector, Action) -> Void
            let function = unsafeBitCast(webView.method(for: selector), to: Function.self)
            let action: Action = { MainActor.assumeIsolated { gate.finish(true) } }
            function(webView, selector, action)
            gate.timer = Task { @MainActor in
                try? await ContinuousClock().sleep(for: timeout)
                gate.finish(false)
            }
        }
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
        _ = try? await webView.browserReplCallAsyncJavaScript(
            "return 0;",
            arguments: [:],
            in: nil,
            contentWorld: BrowserReplAgentWorld.world,
            userGesture: false
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

/// Resumes a continuation exactly once, from whichever of a callback or a
/// timeout comes first.
@MainActor
final class BrowserReplOnce {
    var continuation: CheckedContinuation<Bool, Never>?
    var timer: Task<Void, Never>?

    func finish(_ value: Bool) {
        timer?.cancel()
        timer = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}

/// Converts a REPL tab's virtual clipboard (`clipboard.read` /
/// `clipboard.write` items) to and from the private pasteboard that
/// `BrowserReplPasteboardRedirect` (CmuxBrowser) runs WebKit's Copy, Cut and
/// Paste against.
@MainActor
enum BrowserReplClipboardItems {
    /// Writes the tab's clipboard items (`{ type, base64 }`, MIME types or
    /// raw pasteboard types) to `pasteboard` as one item.
    static func write(_ items: [[String: Any]], to pasteboard: NSPasteboard) {
        pasteboard.writeBrowserReplClipboardItems(items)
    }

    /// Reads `pasteboard`'s first item back as tab clipboard items. Types
    /// with a MIME type use it; WebKit's custom web data keeps its pasteboard
    /// type so a later paste in a page restores it.
    static func read(_ pasteboard: NSPasteboard) -> [[String: Any]] {
        guard let item = pasteboard.pasteboardItems?.first else { return [] }
        var result: [[String: Any]] = []
        var seen = Set<String>()
        for type in item.types {
            guard let mime = mimeType(for: type), !seen.contains(mime), let data = item.data(forType: type) else { continue }
            seen.insert(mime)
            result.append(["type": mime, "base64": data.base64EncodedString()])
        }
        return result
    }

    private static let customWebData = "com.apple.WebKit.custom-pasteboard-data"

    private static func mimeType(for type: NSPasteboard.PasteboardType) -> String? {
        switch type {
        case .string: return "text/plain"
        case .html: return "text/html"
        case .rtf: return "text/rtf"
        case .URL: return "text/uri-list"
        case .png: return "image/png"
        case .tiff: return "image/tiff"
        default:
            if type.rawValue == customWebData { return customWebData }
            guard let uti = UTType(type.rawValue), !uti.isDynamic else { return nil }
            return uti.preferredMIMEType
        }
    }
}
