import AppKit
import CmuxNextBrowser
import Testing
@testable import CmuxNextBrowserAutomation

/// The Playwright key and mouse vocabulary the runtime sends becomes the
/// AppKit events WebKit treats as trusted input.
@Suite struct InputPlanTests {
    @Test func lettersCarryTheirCodeTextAndShift() throws {
        let a = try #require(KeyStroke.resolve(key: "a", code: "KeyA", text: "a", modifiers: []))
        #expect(a.keyCode == 0x00 && a.characters == "a" && a.charactersIgnoringModifiers == "a" && !a.isModifier)
        let upper = try #require(KeyStroke.resolve(key: "A", code: "KeyA", text: "A", modifiers: ["Shift"]))
        #expect(upper.modifierFlags.contains(.shift) && upper.characters == "A" && upper.charactersIgnoringModifiers == "a")
        let hash = try #require(KeyStroke.resolve(key: "#", code: "", text: "#", modifiers: []))
        #expect(hash.keyCode == 0x14 && hash.modifierFlags.contains(.shift))
    }

    @Test func namedKeysUseAppKitFunctionCharacters() throws {
        let enter = try #require(KeyStroke.resolve(key: "Enter", code: "Enter", text: "\r", modifiers: []))
        #expect(enter.keyCode == 0x24 && enter.characters == "\r")
        let left = try #require(KeyStroke.resolve(key: "ArrowLeft", code: "ArrowLeft", text: nil, modifiers: []))
        #expect(left.keyCode == 0x7B && left.characters == "\u{F702}" && left.modifierFlags.contains(.function))
        let backspace = try #require(KeyStroke.resolve(key: "Backspace", code: "", text: nil, modifiers: []))
        #expect(backspace.keyCode == 0x33 && backspace.characters == "\u{7F}")
    }

    @Test func modifierKeysAreFlagsChanged() throws {
        let shift = try #require(KeyStroke.resolve(key: "Shift", code: "ShiftLeft", text: nil, modifiers: []))
        #expect(shift.isModifier && shift.modifierFlags.contains(.shift) && shift.characters.isEmpty)
        let meta = try #require(KeyStroke.resolve(key: "Meta", code: "MetaLeft", text: nil, modifiers: []))
        #expect(meta.keyCode == 0x37 && meta.modifierFlags.contains(.command))
    }

    @Test func metaShortcutsSendTheEditingCommand() throws {
        let selectAll = try #require(KeyStroke.resolve(key: "a", code: "KeyA", text: nil, modifiers: ["Meta"]))
        #expect(selectAll.editingCommand == "selectAll:" && selectAll.characters == "a")
        let redo = try #require(KeyStroke.resolve(key: "Z", code: "KeyZ", text: nil, modifiers: ["Meta", "Shift"]))
        #expect(redo.editingCommand == "redo:")
        let control = try #require(KeyStroke.resolve(key: "a", code: "KeyA", text: nil, modifiers: ["Control"]))
        #expect(control.characters == "\u{01}" && control.editingCommand == nil)
    }

    @Test func keysWithoutAVirtualKeyFallBackToText() {
        #expect(KeyStroke.resolve(key: "é", code: "", text: "é", modifiers: []) == nil)
    }

    @Test func aMoveWhileAButtonIsHeldIsADrag() {
        var plan = MouseEventPlan()
        #expect(plan.eventType(for: "move", button: .left) == .mouseMoved)
        #expect(plan.eventType(for: "down", button: .left) == .leftMouseDown)
        #expect(plan.eventType(for: "move", button: .left) == .leftMouseDragged)
        #expect(plan.eventType(for: "up", button: .left) == .leftMouseUp)
        #expect(plan.eventType(for: "move", button: .left) == .mouseMoved)
        #expect(plan.eventType(for: "down", button: .middle) == .otherMouseDown)
        #expect(plan.eventType(for: "move", button: .left) == .otherMouseDragged)
        #expect(plan.eventType(for: "wheel", button: .left) == nil)
    }

    @Test func cssPointsScaleIntoViewCoordinates() {
        let flipped = MouseEventPlan.viewPoint(css: CGPoint(x: 10, y: 20), scale: 2, viewHeight: 600, flipped: true)
        #expect(flipped == CGPoint(x: 20, y: 40))
        let unflipped = MouseEventPlan.viewPoint(css: CGPoint(x: 10, y: 20), scale: 1, viewHeight: 600, flipped: false)
        #expect(unflipped == CGPoint(x: 10, y: 580))
    }
}
