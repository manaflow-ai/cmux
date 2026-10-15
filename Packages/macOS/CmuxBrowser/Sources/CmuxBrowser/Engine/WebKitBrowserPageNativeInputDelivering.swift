public import CoreGraphics
public import WebKit

/// Delivers trusted input to a WebKit page's web view.
///
/// The browser panel conforms: it replays each step as a native AppKit event
/// straight into WebKit (the path `browser.input_mouse` and the browser REPL
/// use), so the page sees `isTrusted === true` events and the user's focus
/// and cursor do not move. ``WebKitBrowserPage`` declares
/// ``BrowserEngineCapabilities/trustedInput`` only while one is attached.
@MainActor
public protocol WebKitBrowserPageNativeInputDelivering: AnyObject {
    /// Delivers `steps` to `webView` in order.
    /// - Returns: Where the pointer ends, in CSS pixels.
    func deliverNativeInput(_ steps: [BrowserRawInputStep], to webView: WKWebView) async throws -> CGPoint
}

extension BrowserPageInputEvent {
    /// The native input steps that carry out this event.
    public var rawInputSteps: [BrowserRawInputStep] {
        switch self {
        case .click(let point, let button, let clickCount, let modifiers):
            let raw = modifiers.rawInputModifiers
            let count = max(1, min(clickCount, BrowserRawInputRequest.maximumClickCount))
            return [
                .mouseMoved(.point(point), modifiers: raw),
                .mousePressed(.point(point), button: button.rawInputButton, clickCount: count, modifiers: raw),
                .mouseReleased(.point(point), button: button.rawInputButton, clickCount: count, modifiers: raw),
            ]
        case .mouseMove(let point, let modifiers):
            return [.mouseMoved(.point(point), modifiers: modifiers.rawInputModifiers)]
        case .scroll(let point, let deltaX, let deltaY):
            return [.mouseWheel(.point(point), deltaX: deltaX, deltaY: deltaY, modifiers: [])]
        case .key(let key, let modifiers):
            let raw = modifiers.rawInputModifiers
            return [.keyDown(key, modifiers: raw), .keyUp(key, modifiers: raw)]
        case .insertText(let text):
            return [.insertText(text)]
        }
    }
}

extension BrowserPageInputEvent.MouseButton {
    var rawInputButton: BrowserReplMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .middle
        }
    }
}

extension BrowserPageInputEvent.Modifiers {
    var rawInputModifiers: BrowserRawInputModifiers {
        var result: BrowserRawInputModifiers = []
        if contains(.shift) { result.insert(.shift) }
        if contains(.control) { result.insert(.control) }
        if contains(.option) { result.insert(.alt) }
        if contains(.command) { result.insert(.meta) }
        return result
    }
}
