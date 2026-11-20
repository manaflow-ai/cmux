#if DEBUG || CMUX_BENCH_HOOKS
/// A `debug.key` press as Chromium DevTools `Input.dispatchKeyEvent` calls (DEBUG builds): the key-down and the key-up.
///
/// A Chromium page window that is not key (a capture slot never activates the app) takes no AppKit key: Chromium drops
/// a key-down `NSWindow.sendEvent` hands it, so `debug.key` sends the page these trusted DevTools events instead, as
/// `debug.agent_pane click` sends a DevTools press. `name` is a `debug.key` key name (`escape`, `return`, `tab`,
/// `space`, `delete`, `left`, `pageup`, ...) or the character typed; `modifiers` are `cmd`, `shift`, `option`
/// and `control`. A key that types text (no Command or Control) is a `keyDown` with its text, any other a `rawKeyDown`:
///
/// ```swift
/// let press = DebugKeyDevToolsEvents(name: "escape", modifiers: [])
/// for event in press.events { _ = try await page.devTools("Input.dispatchKeyEvent", params: event.params) }
/// ```
public struct DebugKeyDevToolsEvents: Sendable, Equatable {
    /// One `Input.dispatchKeyEvent` call.
    public struct Event: Sendable, Equatable {
        /// `rawKeyDown`, `keyDown` (a key-down that types `text`) or `keyUp`.
        public let type: String
        /// The DOM `key` (`Escape`, `Enter`, `a`).
        public let key: String
        /// The DOM `code` (`Escape`, `Enter`, `KeyA`).
        public let code: String
        /// The legacy key code (`windowsVirtualKeyCode`): 27 for Escape, 65 for A.
        public let keyCode: Int
        /// What the key types, nil when it types nothing.
        public let text: String?
        /// The DevTools modifier mask: Alt 1, Control 2, Meta 4, Shift 8.
        public let modifiers: Int

        /// The call's parameters.
        public var params: [String: any Sendable] {
            var params: [String: any Sendable] = ["type": type, "key": key, "code": code, "windowsVirtualKeyCode": keyCode,
                                                  "modifiers": modifiers]
            if let text { params["text"] = text; params["unmodifiedText"] = text }
            return params
        }
    }

    /// The key-down, then the key-up.
    public let events: [Event]

    /// The press of `name` with `modifiers`.
    /// - Parameters:
    ///   - name: A `debug.key` key name or the character typed.
    ///   - modifiers: `cmd`, `shift`, `option`, `control` (also `command`, `alt`, `opt`, `ctrl`).
    public init(name: String, modifiers: [String]) {
        let held = Set(modifiers.map { $0.lowercased() })
        let mask = (held.isDisjoint(with: ["option", "opt", "alt"]) ? 0 : 1) | (held.isDisjoint(with: ["control", "ctrl"]) ? 0 : 2)
            | (held.isDisjoint(with: ["cmd", "command", "meta"]) ? 0 : 4) | (held.contains("shift") ? 8 : 0)
        let dom = keyNames[name.lowercased()] ?? name
        let press = BrowserPressKey(dom)
        var key = press.key, code = press.code, keyCode = press.keyCode
        // A letter or digit: its own key, `KeyA` / `Digit1` code and upper-case key code (BrowserPressKey names punctuation only).
        if let scalar = dom.unicodeScalars.first, dom.unicodeScalars.count == 1, scalar.isASCII,
           scalar.properties.isAlphabetic || (48...57).contains(scalar.value) {
            let upper = dom.uppercased()
            key = dom
            code = scalar.properties.isAlphabetic ? "Key" + upper : "Digit" + dom
            keyCode = BrowserPressKey(upper).keyCode
        }
        let typed: String? = mask & (2 | 4) != 0 ? nil : key == "Enter" ? "\r" : key.count == 1 ? key : nil
        events = [
            Event(type: typed == nil ? "rawKeyDown" : "keyDown", key: key, code: code, keyCode: keyCode, text: typed, modifiers: mask),
            Event(type: "keyUp", key: key, code: code, keyCode: keyCode, text: nil, modifiers: mask),
        ]
    }
}

/// `debug.key`'s key names (DebugKey's table) as the DOM key names ``BrowserPressKey`` reads.
private let keyNames: [String: String] = [
    "escape": "Escape", "return": "Enter", "enter": "Enter", "tab": "Tab", "space": " ", "delete": "Backspace",
    "forwarddelete": "Delete", "left": "ArrowLeft", "right": "ArrowRight", "up": "ArrowUp", "down": "ArrowDown",
    "pageup": "PageUp", "pagedown": "PageDown", "home": "Home", "end": "End",
]
#endif
