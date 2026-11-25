import Foundation
import Testing
@testable import CmuxNextDaemon

/// `terminal-last-command` (`terminal-last-command-v1`), the read behind Run Last Command Again: the request names the
/// terminal by surface or snake-case terminal id, and the answer carries the command with its exit status, or null.
struct TerminalLastCommandRequestTests {
    @Test func aSurfaceOrATerminalIDNamesTheTerminal() throws {
        let surface = try JSONDecoder().decode(
            JSONValue.self, from: WireCoding.encodeRequest(TerminalLastCommandRequest(.surface(SurfaceID(rawValue: 7))), id: 1))
        #expect(surface == .object(["id": .number(1), "cmd": .string("terminal-last-command"), "surface": .number(7)]))
        let terminal = try JSONDecoder().decode(
            JSONValue.self, from: WireCoding.encodeRequest(TerminalLastCommandRequest(.terminal(TerminalID(rawValue: "abc"))), id: 2))
        #expect(terminal == .object(["id": .number(2), "cmd": .string("terminal-last-command"), "terminal_id": .string("abc")]))
    }

    @Test func theAnswerCarriesTheCommandAndItsExitOrNothing() throws {
        let json = #"{"terminal_id":"abc","last_command":{"command":"make test","exit_code":2,"started_at_ms":"1000","ended_at_ms":"3000"}}"#
        let ran = try JSONDecoder().decode(TerminalLastCommandRequest.Response.self, from: Data(json.utf8))
        #expect(ran.lastCommand == .init(command: "make test", exitCode: 2, startedAtMs: "1000", endedAtMs: "3000"))
        let none = try JSONDecoder().decode(
            TerminalLastCommandRequest.Response.self, from: Data(#"{"terminal_id":"abc","last_command":null}"#.utf8))
        #expect(none.lastCommand == nil)
    }
}
