import CoreGraphics
import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserRawInputRequestTests {
    @Test func devToolsMouseTypesMapOneToOne() throws {
        let pressed = try BrowserRawInputRequest(
            mouseParams: ["type": "mousePressed", "x": 10, "y": 20, "button": "right", "clickCount": 2, "modifiers": 8]
        )
        #expect(pressed.steps == [.mousePressed(.point(CGPoint(x: 10, y: 20)), button: .right, clickCount: 2, modifiers: .shift)])

        let wheel = try BrowserRawInputRequest(mouseParams: ["type": "mouseWheel", "x": 1, "y": 2, "deltaY": 120])
        #expect(wheel.steps == [.mouseWheel(.point(CGPoint(x: 1, y: 2)), deltaX: 0, deltaY: 120, modifiers: [])])

        let moved = try BrowserRawInputRequest(mouseParams: ["type": "mouseMoved"])
        #expect(moved.steps == [.mouseMoved(.pointer, modifiers: [])])
    }

    @Test func commandFormActsAtThePointerForDownUpAndWheel() throws {
        #expect(try BrowserRawInputRequest(mouseParams: ["args": ["move", "10", "10.5"]]).steps
            == [.mouseMoved(.point(CGPoint(x: 10, y: 10.5)), modifiers: [])])
        #expect(try BrowserRawInputRequest(mouseParams: ["args": ["down"]]).steps
            == [.mousePressed(.pointer, button: .left, clickCount: 1, modifiers: [])])
        #expect(try BrowserRawInputRequest(mouseParams: ["args": ["up", "middle"]]).steps
            == [.mouseReleased(.pointer, button: .middle, clickCount: 1, modifiers: [])])
        #expect(try BrowserRawInputRequest(mouseParams: ["args": ["wheel", "-40", "5"]]).steps
            == [.mouseWheel(.pointer, deltaX: 5, deltaY: -40, modifiers: [])])
        #expect(BrowserRawInputLocation.pointer.resolved(pointer: CGPoint(x: 7, y: 9)) == CGPoint(x: 7, y: 9))
    }

    @Test func clickMovesThenPressesAndReleasesEachClick() throws {
        let request = try BrowserRawInputRequest(mouseParams: ["args": ["click", "3", "4", "left", "2"]])
        let at = BrowserRawInputLocation.point(CGPoint(x: 3, y: 4))
        #expect(request.steps == [
            .mouseMoved(at, modifiers: []),
            .mousePressed(at, button: .left, clickCount: 1, modifiers: []),
            .mouseReleased(at, button: .left, clickCount: 1, modifiers: []),
            .mousePressed(at, button: .left, clickCount: 2, modifiers: []),
            .mouseReleased(at, button: .left, clickCount: 2, modifiers: []),
        ])
    }

    @Test func hugeValuesAreClampedInsteadOfTrapping() throws {
        let clicks = try BrowserRawInputRequest(mouseParams: ["args": ["click", "1", "1", "left", "1000000000"]])
        #expect(clicks.steps.count == 1 + 2 * BrowserRawInputRequest.maximumClickCount)

        let pressed = try BrowserRawInputRequest(
            mouseParams: ["type": "mousePressed", "x": 1e300, "y": -1e300, "clickCount": 1e20, "modifiers": 1e300]
        )
        let limit = BrowserRawInputRequest.maximumMagnitude
        #expect(pressed.steps == [.mousePressed(
            .point(CGPoint(x: limit, y: -limit)),
            button: .left,
            clickCount: BrowserRawInputRequest.maximumClickCount,
            modifiers: []
        )])

        let wheel = try BrowserRawInputRequest(mouseParams: ["type": "mouseWheel", "deltaY": 1e300])
        #expect(wheel.steps == [.mouseWheel(.pointer, deltaX: 0, deltaY: limit, modifiers: [])])
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

    @Test func typeInsertsCharactersWithoutAKey() throws {
        #expect(try BrowserRawInputRequest(keyboardParams: ["args": ["type", "aéé🙂b"]]).steps == [
            .keyDown("a", modifiers: []), .keyUp("a", modifiers: []),
            .insertText("éé🙂"),
            .keyDown("b", modifiers: []), .keyUp("b", modifiers: []),
        ])
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
            try BrowserRawInputRequest(mouseParams: [:])
        }
        #expect(throws: BrowserRawInputRequestError.unknownAction("hover")) {
            try BrowserRawInputRequest(mouseParams: ["args": ["hover"]])
        }
        #expect(throws: BrowserRawInputRequestError.missingValue("x y")) {
            try BrowserRawInputRequest(mouseParams: ["args": ["move", "1"]])
        }
        #expect(throws: BrowserRawInputRequestError.unknownButton("back")) {
            try BrowserRawInputRequest(mouseParams: ["args": ["down", "back"]])
        }
        #expect(throws: BrowserRawInputRequestError.missingValue("key")) {
            try BrowserRawInputRequest(keyboardParams: ["type": "keyDown"])
        }
        #expect(throws: BrowserRawInputRequestError.missingValue("deltaY")) {
            try BrowserRawInputRequest(mouseParams: ["args": ["wheel", "x"]])
        }
    }
}
