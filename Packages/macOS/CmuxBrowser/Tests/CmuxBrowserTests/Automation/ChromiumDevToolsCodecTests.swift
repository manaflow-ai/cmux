import Foundation
import Testing

@testable import CmuxBrowser

@Suite("Chromium DevTools codec")
struct ChromiumDevToolsCodecTests {
    let codec = ChromiumDevToolsCodec()

    @Test("undefined decodes to nil and null to NSNull, like WebKit")
    func undefinedAndNull() throws {
        #expect(try codec.evaluationValue(fromJSON: #"{"result":{"type":"undefined"}}"#) == nil)
        let null = try codec.evaluationValue(fromJSON: #"{"result":{"type":"object","subtype":"null","value":null}}"#)
        #expect(null is NSNull)
    }

    @Test("Objects and arrays decode to Foundation collections")
    func collections() throws {
        let value = try codec.evaluationValue(fromJSON: #"{"result":{"type":"object","value":{"a":[1,"x",true]}}}"#)
        let dict = try #require(value as? [String: Any])
        let list = try #require(dict["a"] as? [Any])
        #expect((list[0] as? NSNumber)?.intValue == 1)
        #expect(list[1] as? String == "x")
    }

    @Test("Unserializable numbers keep their numeric meaning")
    func unserializable() throws {
        let nan = try codec.evaluationValue(fromJSON: #"{"result":{"type":"number","unserializableValue":"NaN"}}"#)
        #expect((nan as? NSNumber)?.doubleValue.isNaN == true)
        let inf = try codec.evaluationValue(fromJSON: #"{"result":{"type":"number","unserializableValue":"-Infinity"}}"#)
        #expect((inf as? NSNumber)?.doubleValue == -Double.infinity)
        let big = try codec.evaluationValue(fromJSON: #"{"result":{"type":"bigint","unserializableValue":"12n"}}"#)
        #expect(big as? String == "12n")
    }

    @Test("A rejected promise with a non-Error value reports the value")
    func rejectedPrimitive() {
        #expect(throws: BrowserAutomationPageError.javaScript("Uncaught boom")) {
            _ = try codec.evaluationValue(fromJSON: #"{"result":{},"exceptionDetails":{"text":"Uncaught (in promise)","exception":{"type":"string","value":"boom"}}}"#)
        }
    }

    @Test("Malformed replies are reported, never treated as values")
    func malformed() {
        #expect(throws: BrowserAutomationPageError.self) {
            _ = try codec.evaluationValue(fromJSON: "not json")
        }
        #expect(throws: BrowserAutomationPageError.self) {
            _ = try codec.evaluationValue(fromJSON: "{}")
        }
    }

    @Test("Printable keys type text; named keys and shortcuts do not")
    func keyText() throws {
        let a = try #require(BrowserKeyboardEvent(rawKey: "a"))
        let press = codec.keyEventParams(a, action: .press, modifiers: [])
        #expect(press.map { $0["type"] as? String } == ["keyDown", "keyUp"])
        #expect(press[0]["text"] as? String == "a")
        #expect(press[1]["text"] == nil)

        let arrow = try #require(BrowserKeyboardEvent(rawKey: "ArrowDown"))
        let arrowDown = codec.keyEventParams(arrow, action: .keyDown, modifiers: [])
        #expect(arrowDown.map { $0["type"] as? String } == ["rawKeyDown"])
        #expect(arrowDown[0]["text"] == nil)
        #expect(arrowDown[0]["nativeVirtualKeyCode"] as? Int == 125)

        let shortcut = codec.keyEventParams(a, action: .press, modifiers: [.command])
        #expect(shortcut[0]["type"] as? String == "rawKeyDown")
        #expect(shortcut[0]["modifiers"] as? Int == 4)
    }

    @Test("A modifier key reports its own bit while down and clears it on up")
    func modifierKey() throws {
        let shift = try #require(BrowserKeyboardEvent(rawKey: "Shift"))
        let down = codec.keyEventParams(shift, action: .keyDown, modifiers: [])
        let up = codec.keyEventParams(shift, action: .keyUp, modifiers: [.shift])
        #expect(down[0]["modifiers"] as? Int == 8)
        #expect(up[0]["modifiers"] as? Int == 0)
    }

}
