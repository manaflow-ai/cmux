import Foundation
import Testing
@testable import CmuxNextDaemon

/// `terminal-resume-command` (`resume-command`): an absent `command` reads,
/// a string sets and an explicit null clears, so the three changes must
/// reach the daemon as exactly those three shapes.
struct TerminalResumeCommandRequestTests {
    static func fields(_ change: TerminalResumeCommandRequest.Change) throws -> JSONValue {
        let data = try WireCoding.encodeRequest(TerminalResumeCommandRequest(.surface(SurfaceID(rawValue: 7)), change: change), id: 1)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test func readSetAndClearAreAbsentStringAndNull() throws {
        let base: [String: JSONValue] = ["id": .number(1), "cmd": .string("terminal-resume-command"), "surface": .number(7)]
        #expect(try Self.fields(.read) == .object(base))
        #expect(try Self.fields(.set("npm run dev")) == .object(base.merging(["command": .string("npm run dev")]) { $1 }))
        #expect(try Self.fields(.clear) == .object(base.merging(["command": .null]) { $1 }))
    }

    @Test func aTerminalIDTargetUsesTheSnakeCaseField() throws {
        let data = try WireCoding.encodeRequest(TerminalResumeCommandRequest(.terminal(TerminalID(rawValue: "abc"))), id: 2)
        let fields = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(fields == .object(["id": .number(2), "cmd": .string("terminal-resume-command"), "terminal_id": .string("abc")]))
    }

    @Test func theResponseNamesTheStoredCommandOrNone() throws {
        let set = try JSONDecoder().decode(TerminalResumeCommandRequest.Response.self, from: Data(#"{"terminal_id":"abc","command":"ls"}"#.utf8))
        #expect(set.command == "ls")
        let none = try JSONDecoder().decode(TerminalResumeCommandRequest.Response.self, from: Data(#"{"terminal_id":"abc","command":null}"#.utf8))
        #expect(none.command == nil)
    }
}
