import Foundation
import Testing
@testable import CmuxTerminalAccess

@Suite struct MouseEventTests {
    @Test func parsesPressLeftWithCoords() throws {
        let ev = try MouseEvent.parse([
            "action": "press", "button": "left", "x": 5, "y": 7, "mods": ["ctrl"]
        ])
        #expect(ev.action == .press)
        #expect(ev.button == .left)
        #expect(ev.x == 5)
        #expect(ev.y == 7)
        #expect(ev.mods == [.ctrl])
    }

    @Test func parsesScrollWithoutButton() throws {
        let ev = try MouseEvent.parse([
            "action": "scroll", "x": 1, "y": 2, "scrollDy": -3
        ])
        #expect(ev.action == .scroll)
        #expect(ev.button == nil)
        #expect(ev.scrollDy == -3)
    }

    @Test func rejectsMissingCoords() {
        #expect(throws: MouseEvent.ParseError.self) {
            _ = try MouseEvent.parse(["action": "press"])
        }
    }

    @Test func rejectsUnknownAction() {
        #expect(throws: MouseEvent.ParseError.self) {
            _ = try MouseEvent.parse(["action": "tap", "x": 0, "y": 0])
        }
    }
}
