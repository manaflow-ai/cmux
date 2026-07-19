import AppKit
import Foundation
import WebKit

/// Applies validated guest pointer/keyboard events to a shared browser pane's
/// webview (slice 3). Only `BrowserPanel` panes are pointer-driven; agent
/// panes take input through the composer sync path instead.
///
/// Pointer and key events are synthesized as `NSEvent`s and delivered
/// directly to the webview's responder methods, the same path a real local
/// event takes once AppKit routes it, so WebKit generates ordinary trusted
/// DOM events. Wheel events are the exception: AppKit has no public
/// constructor for scroll `NSEvent`s bound to a window, so scrolling is
/// applied via JavaScript on the scrollable element under the pointer
/// (page-level `window.scrollBy` as the last resort).
@MainActor
final class ShareBrowserInputApplier {
    /// Panes whose synthesized left button is currently down, so moves during
    /// a drag are delivered as `leftMouseDragged`.
    private var leftButtonDownPanes = Set<String>()

    func reset() {
        leftButtonDownPanes.removeAll()
    }

    // MARK: - Pointer

    func applyPointer(_ event: ShareGuestPointer, to webView: WKWebView) {
        guard let window = webView.window else { return }
        let bounds = webView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let x = bounds.minX + min(max(event.x, 0), 1) * bounds.width
        let yFromTop = min(max(event.y, 0), 1) * bounds.height
        let point = NSPoint(
            x: x,
            y: webView.isFlipped ? bounds.minY + yFromTop : bounds.maxY - yFromTop
        )
        let locationInWindow = webView.convert(point, to: nil)

        switch event.action {
        case "wheel":
            applyWheel(event, to: webView, viewPoint: point)
            return
        case "down":
            if event.button ?? 0 == 0 {
                leftButtonDownPanes.insert(event.pane)
            }
        case "up":
            if event.button ?? 0 == 0 {
                leftButtonDownPanes.remove(event.pane)
            }
        default:
            break
        }

        guard let type = eventType(for: event) else { return }
        guard let nsEvent = NSEvent.mouseEvent(
            with: type,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: (type == .leftMouseDown || type == .leftMouseUp
                || type == .rightMouseDown || type == .rightMouseUp) ? 1 : 0,
            pressure: (type == .leftMouseDown || type == .rightMouseDown) ? 1 : 0
        ) else { return }

        switch type {
        case .leftMouseDown:
            webView.mouseDown(with: nsEvent)
        case .leftMouseUp:
            webView.mouseUp(with: nsEvent)
        case .rightMouseDown:
            webView.rightMouseDown(with: nsEvent)
        case .rightMouseUp:
            webView.rightMouseUp(with: nsEvent)
        case .leftMouseDragged:
            webView.mouseDragged(with: nsEvent)
        case .mouseMoved:
            webView.mouseMoved(with: nsEvent)
        default:
            break
        }
    }

    private func eventType(for event: ShareGuestPointer) -> NSEvent.EventType? {
        let isRight = (event.button ?? 0) == 2
        switch event.action {
        case "move":
            return leftButtonDownPanes.contains(event.pane) ? .leftMouseDragged : .mouseMoved
        case "down":
            return isRight ? .rightMouseDown : .leftMouseDown
        case "up":
            return isRight ? .rightMouseUp : .leftMouseUp
        default:
            return nil
        }
    }

    private func applyWheel(_ event: ShareGuestPointer, to webView: WKWebView, viewPoint: NSPoint) {
        let dx = event.dx ?? 0
        let dy = event.dy ?? 0
        guard dx != 0 || dy != 0 else { return }
        // CSS pixel coordinates for elementFromPoint (top-left origin).
        let bounds = webView.bounds
        let cssX = min(max(event.x, 0), 1) * bounds.width
        let cssY = min(max(event.y, 0), 1) * bounds.height
        let script = """
        (() => {
          let el = document.elementFromPoint(\(cssX), \(cssY));
          while (el && el !== document.body) {
            const s = getComputedStyle(el);
            const scrollable = /(auto|scroll)/.test(s.overflowY + s.overflowX)
              && (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth);
            if (scrollable) { el.scrollBy(\(dx), \(dy)); return; }
            el = el.parentElement;
          }
          window.scrollBy(\(dx), \(dy));
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in }
    }

    // MARK: - Keyboard

    func applyKey(_ event: ShareGuestWebKey, to webView: WKWebView) {
        guard let window = webView.window else { return }
        var flags: NSEvent.ModifierFlags = []
        if event.shift == true { flags.insert(.shift) }
        if event.ctrl == true { flags.insert(.control) }
        if event.alt == true { flags.insert(.option) }
        if event.meta == true { flags.insert(.command) }

        guard let mapped = ShareWebKeyCodeMap.map(key: event.key, code: event.code) else {
            // Unmapped key: best-effort JS KeyboardEvent. Synthetic
            // (untrusted) DOM events may be ignored by contenteditable and
            // default actions; acceptable for uncommon keys.
            dispatchJSKey(event, to: webView)
            return
        }
        guard let nsEvent = NSEvent.keyEvent(
            with: event.down ? .keyDown : .keyUp,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: mapped.characters,
            charactersIgnoringModifiers: mapped.charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: mapped.keyCode
        ) else { return }
        if event.down {
            webView.keyDown(with: nsEvent)
        } else {
            webView.keyUp(with: nsEvent)
        }
    }

    private func dispatchJSKey(_ event: ShareGuestWebKey, to webView: WKWebView) {
        guard event.down,
              let keyJSON = jsonString(event.key),
              let codeJSON = jsonString(event.code) else { return }
        let script = """
        (() => {
          const target = document.activeElement || document.body;
          if (!target) { return; }
          target.dispatchEvent(new KeyboardEvent("keydown", {
            key: \(keyJSON), code: \(codeJSON), bubbles: true, cancelable: true,
            altKey: \(event.alt == true), ctrlKey: \(event.ctrl == true),
            metaKey: \(event.meta == true), shiftKey: \(event.shift == true)
          }));
        })();
        """
        webView.evaluateJavaScript(script) { _, _ in }
    }

    private func jsonString(_ value: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8),
              encoded.count >= 2 else { return nil }
        return String(encoded.dropFirst().dropLast())
    }
}

/// Maps web `KeyboardEvent.code`/`key` pairs to macOS virtual key codes and
/// the character payloads `NSEvent.keyEvent` needs. Covers the common typing
/// set; unknown codes fall back to JS dispatch in the applier.
enum ShareWebKeyCodeMap {
    struct MappedKey {
        let keyCode: UInt16
        let characters: String
        let charactersIgnoringModifiers: String
    }

    private static let virtualKeyCodesByWebCode: [String: UInt16] = [
        "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5,
        "KeyZ": 6, "KeyX": 7, "KeyC": 8, "KeyV": 9, "KeyB": 11, "KeyQ": 12,
        "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16, "KeyT": 17,
        "Digit1": 18, "Digit2": 19, "Digit3": 20, "Digit4": 21, "Digit6": 22,
        "Digit5": 23, "Equal": 24, "Digit9": 25, "Digit7": 26, "Minus": 27,
        "Digit8": 28, "Digit0": 29, "BracketRight": 30, "KeyO": 31, "KeyU": 32,
        "BracketLeft": 33, "KeyI": 34, "KeyP": 35, "Enter": 36, "KeyL": 37,
        "KeyJ": 38, "Quote": 39, "KeyK": 40, "Semicolon": 41, "Backslash": 42,
        "Comma": 43, "Slash": 44, "KeyN": 45, "KeyM": 46, "Period": 47,
        "Tab": 48, "Space": 49, "Backquote": 50, "Backspace": 51, "Escape": 53,
        "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
        "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121, "Delete": 117,
    ]

    private static let specialCharactersByKey: [String: String] = [
        "Enter": "\r",
        "Tab": "\t",
        "Backspace": "\u{7F}",
        "Escape": "\u{1B}",
        "ArrowUp": "\u{F700}",
        "ArrowDown": "\u{F701}",
        "ArrowLeft": "\u{F702}",
        "ArrowRight": "\u{F703}",
        "Home": "\u{F729}",
        "End": "\u{F72B}",
        "PageUp": "\u{F72C}",
        "PageDown": "\u{F72D}",
        "Delete": "\u{F728}",
    ]

    static func map(key: String, code: String) -> MappedKey? {
        guard let keyCode = virtualKeyCodesByWebCode[code] else { return nil }
        let characters: String
        if let special = specialCharactersByKey[key] {
            characters = special
        } else if key.count == 1 {
            characters = key
        } else if key == " " || code == "Space" {
            characters = " "
        } else {
            return nil
        }
        return MappedKey(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: characters
        )
    }
}
