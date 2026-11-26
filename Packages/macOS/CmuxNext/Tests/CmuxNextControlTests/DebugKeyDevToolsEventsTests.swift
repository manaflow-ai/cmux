#if DEBUG
import CmuxNextControl
import Testing

/// `debug.key` into a Chromium chat page that is not key (``DebugKeyDevToolsEvents``). In a capture slot the app is never
/// active, so no window is key, and Chromium drops a key AppKit hands its page window: on a fleet Mac (esc6 capture,
/// 2026-11-20) `debug.key {"key": "escape", "target": "page"}` left the composer's + menu open and
/// `{"key": "return", "target": "page"}` sent no prompt. DevTools key events reach the page there, as a DevTools press does.
@Suite struct DebugKeyDevToolsEventsTests {
    @Test func escapeIsARawKeyDownThenAKeyUp() {
        let press = DebugKeyDevToolsEvents(name: "escape", modifiers: [])
        #expect(press.events.map(\.type) == ["rawKeyDown", "keyUp"])
        #expect(press.events.allSatisfy { $0.key == "Escape" && $0.code == "Escape" && $0.keyCode == 27 && $0.text == nil })
    }

    @Test func returnTypesACarriageReturn() {
        let down = DebugKeyDevToolsEvents(name: "return", modifiers: []).events.first
        #expect(down?.type == "keyDown")
        #expect(down?.key == "Enter")
        #expect(down?.keyCode == 13)
        #expect(down?.text == "\r")
    }

    @Test func aLetterTypesItselfAndShiftKeepsItsCase() {
        let plain = DebugKeyDevToolsEvents(name: "a", modifiers: []).events.first
        #expect(plain?.key == "a")
        #expect(plain?.code == "KeyA")
        #expect(plain?.keyCode == 65)
        #expect(plain?.text == "a")
        let shifted = DebugKeyDevToolsEvents(name: "A", modifiers: ["shift"]).events.first
        #expect(shifted?.text == "A")
        #expect(shifted?.modifiers == 8)
    }

    @Test func aCommandChordTypesNothing() {
        let down = DebugKeyDevToolsEvents(name: "a", modifiers: ["control", "option", "cmd"]).events.first
        #expect(down?.type == "rawKeyDown")
        #expect(down?.text == nil)
        #expect(down?.modifiers == 1 | 2 | 4)
    }

    @Test(arguments: [("tab", "Tab"), ("space", " "), ("delete", "Backspace"), ("forwarddelete", "Delete"), ("left", "ArrowLeft"),
                      ("down", "ArrowDown"), ("pageup", "PageUp"), ("end", "End")])
    func namedKeysMapToTheirDOMKey(name: String, key: String) {
        #expect(DebugKeyDevToolsEvents(name: name, modifiers: []).events.first?.key == key)
    }
}
#endif
