import AppKit
import Testing

@testable import CmuxBrowser

@Suite("Browser REPL key mapping")
struct BrowserReplKeyStrokeTests {
    struct Case: Sendable, CustomStringConvertible {
        let key: String
        let code: String
        let text: String?
        let modifiers: [String]
        let keyCode: UInt16
        let characters: String
        let ignoring: String
        let flags: NSEvent.ModifierFlags
        let command: String?

        var description: String { "\(modifiers.joined(separator: "+"))+\(key)/\(code)" }
    }

    static let cases: [Case] = [
        Case(key: "a", code: "KeyA", text: "a", modifiers: [], keyCode: 0, characters: "a", ignoring: "a", flags: [], command: nil),
        Case(key: "C", code: "KeyC", text: "C", modifiers: ["Shift"], keyCode: 8, characters: "C", ignoring: "c", flags: [.shift], command: nil),
        Case(key: "a", code: "KeyA", text: "", modifiers: ["Meta"], keyCode: 0, characters: "a", ignoring: "a", flags: [.command], command: "selectAll:"),
        Case(key: "z", code: "KeyZ", text: "", modifiers: ["Meta", "Shift"], keyCode: 6, characters: "z", ignoring: "z", flags: [.command, .shift], command: "redo:"),
        Case(key: "Enter", code: "Enter", text: "\r", modifiers: [], keyCode: 36, characters: "\r", ignoring: "\r", flags: [], command: nil),
        Case(key: "Backspace", code: "Backspace", text: "", modifiers: [], keyCode: 51, characters: "\u{8}", ignoring: "\u{8}", flags: [], command: nil),
        Case(key: "End", code: "End", text: "", modifiers: [], keyCode: 119, characters: "\u{F72B}", ignoring: "\u{F72B}", flags: [], command: nil),
        Case(key: "ArrowLeft", code: "ArrowLeft", text: "", modifiers: ["Alt"], keyCode: 123, characters: "\u{F702}", ignoring: "\u{F702}", flags: [.option], command: nil),
        Case(key: "!", code: "Digit1", text: "!", modifiers: ["Shift"], keyCode: 18, characters: "!", ignoring: "1", flags: [.shift], command: nil),
        Case(key: "c", code: "KeyC", text: "", modifiers: ["Control"], keyCode: 8, characters: "\u{3}", ignoring: "c", flags: [.control], command: nil),
        Case(key: "Tab", code: "", text: nil, modifiers: [], keyCode: 48, characters: "\t", ignoring: "\t", flags: [], command: nil),
        Case(key: "b", code: "", text: nil, modifiers: [], keyCode: 11, characters: "b", ignoring: "b", flags: [], command: nil),
        Case(key: "b", code: "KeyB", text: "", modifiers: ["Meta"], keyCode: 11, characters: "b", ignoring: "b", flags: [.command], command: "bold"),
        Case(key: "i", code: "KeyI", text: "", modifiers: ["Meta"], keyCode: 34, characters: "i", ignoring: "i", flags: [.command], command: "italic"),
        Case(key: "u", code: "KeyU", text: "", modifiers: ["Meta"], keyCode: 32, characters: "u", ignoring: "u", flags: [.command], command: "underline"),
        Case(key: "K", code: "KeyK", text: nil, modifiers: ["Alt", "Shift"], keyCode: 40, characters: "", ignoring: "k", flags: [.option, .shift], command: nil),
    ]

    @Test("Playwright keys resolve to the AppKit event WebKit receives", arguments: cases)
    func resolvesKey(_ testCase: Case) throws {
        let stroke = try #require(BrowserReplKeyStroke.resolve(
            key: testCase.key,
            code: testCase.code,
            text: testCase.text,
            modifiers: testCase.modifiers
        ))
        #expect(stroke.keyCode == testCase.keyCode)
        #expect(stroke.characters == testCase.characters)
        #expect(stroke.charactersIgnoringModifiers == testCase.ignoring)
        #expect(stroke.modifierFlags.intersection([.shift, .control, .option, .command]) == testCase.flags)
        #expect(stroke.editingCommand == testCase.command)
        #expect(stroke.modifierKey == nil)
    }

    @Test("Modifier keys carry their own flag and no characters")
    func modifierKey() throws {
        let stroke = try #require(BrowserReplKeyStroke.resolve(key: "Shift", code: "ShiftLeft", text: nil, modifiers: ["Shift"]))
        #expect(stroke.keyCode == 56)
        #expect(stroke.modifierKey == .shift)
        #expect(stroke.characters.isEmpty)
        #expect(stroke.location == 1)
    }

    @Test("Keys with no macOS virtual key fall back to text insertion")
    func unmappedKey() {
        #expect(BrowserReplKeyStroke.resolve(key: "é", code: "", text: "é", modifiers: []) == nil)
    }

    @Test("Unknown modifier names are ignored")
    func unknownModifier() {
        #expect(BrowserReplKeyStroke.modifierFlags(named: ["Hyper", "Meta"]) == .command)
    }
}

@Suite("Browser REPL mouse mapping")
struct BrowserReplMouseStateTests {
    @Test("A move while a button is held is a drag of that button")
    func moveWhileHeldIsDrag() {
        var state = BrowserReplMouseState()
        #expect(state.eventType(forType: "move", button: .left) == .mouseMoved)
        #expect(state.eventType(forType: "down", button: .left) == .leftMouseDown)
        #expect(state.eventType(forType: "move", button: .left) == .leftMouseDragged)
        #expect(state.eventType(forType: "up", button: .left) == .leftMouseUp)
        #expect(state.eventType(forType: "move", button: .left) == .mouseMoved)
    }

    @Test("Right and middle buttons map to their own AppKit events")
    func otherButtons() {
        var state = BrowserReplMouseState()
        #expect(state.eventType(forType: "down", button: .right) == .rightMouseDown)
        #expect(state.eventType(forType: "move", button: .right) == .rightMouseDragged)
        #expect(state.eventType(forType: "up", button: .right) == .rightMouseUp)
        #expect(state.eventType(forType: "down", button: .middle) == .otherMouseDown)
        #expect(state.eventType(forType: "up", button: .middle) == .otherMouseUp)
        #expect(state.eventType(forType: "wheel", button: .left) == nil)
        #expect(state.pressedButtons.isEmpty)
    }

    @Test("CSS pixels convert to view points through zoom and flipping")
    func coordinateConversion() {
        let flipped = CGPoint(x: 100, y: 40).browserReplViewPoint(
            cssPerPoint: 1,
            viewIsFlipped: true,
            viewHeight: 600
        )
        #expect(flipped == CGPoint(x: 100, y: 40))
        let zoomed = CGPoint(x: 100, y: 40).browserReplViewPoint(
            cssPerPoint: 0.5,
            viewIsFlipped: false,
            viewHeight: 600
        )
        #expect(zoomed == CGPoint(x: 200, y: 520))
    }
}

/// The REPL is untrusted, so a wheel call's deltas are whatever it sends:
/// any finite number (the runtime's own check is not a guard), or not a
/// number at all. Building the event must never trap the app.
@Suite("Browser REPL wheel deltas")
struct BrowserReplWheelDeltaTests {
    @Test func ordinaryDeltasBecomeWheelCountsInTheFingersDirection() {
        #expect(BrowserReplWheelDelta(deltaX: 10.4, deltaY: -120.6) == BrowserReplWheelDelta(vertical: 121, horizontal: -10))
    }

    @Test(arguments: [1e300, -1e300, 9.3e18, -9.3e18, Double(Int32.max) * 4])
    func outOfRangeDeltasClampInsteadOfTrapping(_ delta: Double) {
        let wheel = BrowserReplWheelDelta(deltaX: delta, deltaY: delta)
        let expected: Int32 = delta > 0 ? .min : .max
        #expect(wheel.vertical == expected)
        #expect(wheel.horizontal == expected)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteDeltasAreRefused(_ delta: Double) {
        #expect(BrowserReplWheelDelta(validatingDeltaX: delta, deltaY: 0) == nil)
        #expect(BrowserReplWheelDelta(validatingDeltaX: 0, deltaY: delta) == nil)
    }
}
