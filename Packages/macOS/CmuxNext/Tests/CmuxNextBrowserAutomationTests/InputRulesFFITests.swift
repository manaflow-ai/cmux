import AppKit
import Testing
@testable import CmuxNextBrowserAutomation

/// The input rules answered by Rust (cmux-browser-rules `input.rs`) give the key events, mouse
/// event types and view points the Swift copy gave.
@Suite struct InputRulesFFITests {
    @Test func aLetterIsItsVirtualKey() throws {
        let stroke = try #require(KeyStroke.resolve(key: "a", code: "KeyA", text: "a", modifiers: []))
        #expect(stroke.keyCode == 0x00)
        #expect(stroke.modifierFlags == [])
        #expect(stroke.characters == "a")
        #expect(stroke.charactersIgnoringModifiers == "a")
        #expect(!stroke.isModifier)
        #expect(stroke.editingCommand == nil)
    }

    @Test func aShiftedKeyAddsShiftAndKeepsItsBase() throws {
        let upper = try #require(KeyStroke.resolve(key: "A", code: "", text: nil, modifiers: []))
        #expect(upper.keyCode == 0x00)
        #expect(upper.modifierFlags == .shift)
        #expect(upper.characters == "A")
        #expect(upper.charactersIgnoringModifiers == "a")
        let hash = try #require(KeyStroke.resolve(key: "#", code: "", text: nil, modifiers: []))
        #expect(hash.keyCode == 0x14)
        #expect(hash.characters == "#")
        #expect(hash.charactersIgnoringModifiers == "3")
    }

    @Test func aModifierKeyIsAFlagsChange() throws {
        let stroke = try #require(KeyStroke.resolve(key: "Shift", code: "ShiftLeft", text: nil, modifiers: ["Control"]))
        #expect(stroke.keyCode == 0x38)
        #expect(stroke.modifierFlags == [.shift, .control])
        #expect(stroke.isModifier)
        #expect(stroke.characters.isEmpty)
    }

    @Test func metaShortcutsCarryTheirEditingCommand() throws {
        let all = try #require(KeyStroke.resolve(key: "a", code: "KeyA", text: nil, modifiers: ["Meta"]))
        #expect(all.editingCommand == "selectAll:")
        #expect(all.modifierFlags == .command)
        let redo = try #require(KeyStroke.resolve(key: "z", code: "KeyZ", text: nil, modifiers: ["Meta", "Shift"]))
        #expect(redo.editingCommand == "redo:")
    }

    @Test func controlLettersAreControlCharacters() throws {
        let stroke = try #require(KeyStroke.resolve(key: "c", code: "KeyC", text: "c", modifiers: ["Control"]))
        #expect(stroke.characters == "\u{03}")
    }

    @Test func namedAndFunctionKeys() throws {
        let enter = try #require(KeyStroke.resolve(key: "Enter", code: "", text: nil, modifiers: []))
        #expect(enter.keyCode == 0x24)
        #expect(enter.characters == "\r")
        let up = try #require(KeyStroke.resolve(key: "ArrowUp", code: "ArrowUp", text: nil, modifiers: []))
        #expect(up.modifierFlags.contains(.function))
        #expect(up.characters == String(Character(UnicodeScalar(0xF700)!)))
        let pad = try #require(KeyStroke.resolve(key: "1", code: "Numpad1", text: "1", modifiers: []))
        #expect(pad.modifierFlags.contains(.numericPad))
    }

    @Test func aKeyWithNoVirtualKeyIsNil() {
        #expect(KeyStroke.resolve(key: "é", code: "", text: "é", modifiers: []) == nil)
        #expect(KeyStroke.resolve(key: "Unidentified", code: "", text: nil, modifiers: []) == nil)
    }

    @Test func aMoveWhileHeldIsADrag() {
        var plan = MouseEventPlan()
        #expect(plan.eventType(for: "move", button: .left) == .mouseMoved)
        #expect(plan.eventType(for: "down", button: .left) == .leftMouseDown)
        #expect(plan.held == [.left])
        #expect(plan.eventType(for: "move", button: .left) == .leftMouseDragged)
        #expect(plan.eventType(for: "up", button: .left) == .leftMouseUp)
        #expect(plan.held.isEmpty)
        #expect(plan.eventType(for: "down", button: .right) == .rightMouseDown)
        #expect(plan.eventType(for: "move", button: .left) == .rightMouseDragged)
        #expect(plan.eventType(for: "down", button: .middle) == .otherMouseDown)
        #expect(plan.held == [.right, .middle])
    }

    @Test func aWheelOrUnknownTypeIsNil() {
        var plan = MouseEventPlan()
        #expect(plan.eventType(for: "wheel", button: .left) == nil)
        #expect(plan.eventType(for: "tap", button: .left) == nil)
        #expect(plan.held.isEmpty)
    }

    @Test func viewPointScalesAndFlips() {
        let css = CGPoint(x: 10, y: 20)
        #expect(MouseEventPlan.viewPoint(css: css, scale: 2, viewHeight: 100, flipped: true) == CGPoint(x: 20, y: 40))
        #expect(MouseEventPlan.viewPoint(css: css, scale: 2, viewHeight: 100, flipped: false) == CGPoint(x: 20, y: 60))
        #expect(MouseEventPlan.viewPoint(css: css, scale: 0, viewHeight: 100, flipped: true) == CGPoint(x: 10, y: 20))
    }
}
