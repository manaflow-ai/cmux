import CoreGraphics
import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserRawInputRequestTests {
    private let pointer = CGPoint(x: 7, y: 9)

    @Test func devToolsMouseTypesMapOneToOne() throws {
        let pressed = try BrowserRawInputRequest(
            mouseParams: ["type": "mousePressed", "x": 10, "y": 20, "button": "right", "clickCount": 2, "modifiers": 8],
            pointer: pointer
        )
        #expect(pressed.steps == [.mousePressed(CGPoint(x: 10, y: 20), button: .right, clickCount: 2, modifiers: .shift)])

        let wheel = try BrowserRawInputRequest(
            mouseParams: ["type": "mouseWheel", "x": 1, "y": 2, "deltaY": 120],
            pointer: pointer
        )
        #expect(wheel.steps == [.mouseWheel(CGPoint(x: 1, y: 2), deltaX: 0, deltaY: 120, modifiers: [])])

        let moved = try BrowserRawInputRequest(mouseParams: ["type": "mouseMoved"], pointer: pointer)
        #expect(moved.steps == [.mouseMoved(pointer, modifiers: [])])
    }

    @Test func commandFormUsesThePointerForDownUpAndWheel() throws {
        #expect(try BrowserRawInputRequest(mouseParams: ["args": ["move", "10", "10.5"]], pointer: pointer).steps
            == [.mouseMoved(CGPoint(x: 10, y: 10.5), modifiers: [])])
        #expect(try BrowserRawInputRequest(mouseParams: ["args": ["down"]], pointer: pointer).steps
            == [.mousePressed(pointer, button: .left, clickCount: 1, modifiers: [])])
        #expect(try BrowserRawInputRequest(mouseParams: ["args": ["up", "middle"]], pointer: pointer).steps
            == [.mouseReleased(pointer, button: .middle, clickCount: 1, modifiers: [])])
        #expect(try BrowserRawInputRequest(mouseParams: ["args": ["wheel", "-40", "5"]], pointer: pointer).steps
            == [.mouseWheel(pointer, deltaX: 5, deltaY: -40, modifiers: [])])
    }

    @Test func clickMovesThenPressesAndReleasesEachClick() throws {
        let request = try BrowserRawInputRequest(mouseParams: ["args": ["click", "3", "4", "left", "2"]], pointer: pointer)
        let at = CGPoint(x: 3, y: 4)
        #expect(request.steps == [
            .mouseMoved(at, modifiers: []),
            .mousePressed(at, button: .left, clickCount: 1, modifiers: []),
            .mouseReleased(at, button: .left, clickCount: 1, modifiers: []),
            .mousePressed(at, button: .left, clickCount: 2, modifiers: []),
            .mouseReleased(at, button: .left, clickCount: 2, modifiers: []),
        ])
    }

    @Test func keyboardCommandForm() throws {
        #expect(try BrowserRawInputRequest(keyboardParams: ["args": ["press", "Enter"], "modifiers": 4]).steps
            == [.keyDown("Enter", modifiers: .meta), .keyUp("Enter", modifiers: .meta)])
        #expect(try BrowserRawInputRequest(keyboardParams: ["args": ["type", "hi", "x"]]).steps == [
            .keyDown("h", modifiers: []), .keyUp("h", modifiers: []),
            .keyDown("i", modifiers: []), .keyUp("i", modifiers: []),
            .keyDown(" ", modifiers: []), .keyUp(" ", modifiers: []),
            .keyDown("x", modifiers: []), .keyUp("x", modifiers: []),
        ])
        #expect(try BrowserRawInputRequest(keyboardParams: ["args": ["inserttext", "héllo", "wörld"]]).steps
            == [.insertText("héllo wörld")])
    }

    @Test func keyboardDevToolsForm() throws {
        #expect(try BrowserRawInputRequest(keyboardParams: ["type": "rawKeyDown", "key": "a", "modifiers": 2]).steps
            == [.keyDown("a", modifiers: .control)])
        #expect(try BrowserRawInputRequest(keyboardParams: ["type": "keyUp", "key": "a"]).steps
            == [.keyUp("a", modifiers: [])])
        #expect(try BrowserRawInputRequest(keyboardParams: ["type": "char", "text": "é"]).steps
            == [.insertText("é")])
    }

    @Test func malformedRequestsSayWhatIsMissing() {
        #expect(throws: BrowserRawInputRequestError.missingAction) {
            try BrowserRawInputRequest(mouseParams: [:], pointer: .zero)
        }
        #expect(throws: BrowserRawInputRequestError.unknownAction("hover")) {
            try BrowserRawInputRequest(mouseParams: ["args": ["hover"]], pointer: .zero)
        }
        #expect(throws: BrowserRawInputRequestError.missingValue("x y")) {
            try BrowserRawInputRequest(mouseParams: ["args": ["move", "1"]], pointer: .zero)
        }
        #expect(throws: BrowserRawInputRequestError.unknownButton("back")) {
            try BrowserRawInputRequest(mouseParams: ["args": ["down", "back"]], pointer: .zero)
        }
        #expect(throws: BrowserRawInputRequestError.missingValue("key")) {
            try BrowserRawInputRequest(keyboardParams: ["type": "keyDown"])
        }
        #expect(throws: BrowserRawInputRequestError.missingValue("deltaY")) {
            try BrowserRawInputRequest(mouseParams: ["args": ["wheel", "x"]], pointer: .zero)
        }
    }
}
