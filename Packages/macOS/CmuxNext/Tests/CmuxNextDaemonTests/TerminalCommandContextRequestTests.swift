import Foundation
import Testing
@testable import CmuxNextDaemon

/// `terminal-command-context` (`terminal-command-context-v1`), the read behind Fix and Send Last Output to Chat: the
/// request names the surface and what the chat text asks for, and the answer carries the command with its output,
/// status, folder and chat text, or null.
struct TerminalCommandContextRequestTests {
    @Test func theRequestNamesTheSurfaceAndTheIntent() throws {
        let fix = try JSONDecoder().decode(
            JSONValue.self, from: WireCoding.encodeRequest(TerminalCommandContextRequest(surface: SurfaceID(rawValue: 7), intent: .fix), id: 1))
        #expect(fix == .object(["id": .number(1), "cmd": .string("terminal-command-context"), "surface": .number(7), "intent": .string("fix")]))
        let context = try JSONDecoder().decode(
            JSONValue.self, from: WireCoding.encodeRequest(TerminalCommandContextRequest(surface: SurfaceID(rawValue: 7), intent: .context), id: 2))
        #expect(context == .object(["id": .number(2), "cmd": .string("terminal-command-context"), "surface": .number(7), "intent": .string("context")]))
    }

    @Test func theAnswerCarriesTheCommandAndItsChatTextOrNothing() throws {
        let json = #"{"context":{"command":"cargo test","exit_code":101,"cwd":"/work","output":"error","truncated":false,"text":"This command failed (exit code 101)."}}"#
        let read = try JSONDecoder().decode(TerminalCommandContextRequest.Response.self, from: Data(json.utf8))
        #expect(read.context == .init(command: "cargo test", exitCode: 101, cwd: "/work", output: "error", truncated: false,
                                      text: "This command failed (exit code 101)."))
        let unknown = #"{"context":{"command":null,"exit_code":null,"cwd":null,"output":"","truncated":true,"text":"x"}}"#
        #expect(try JSONDecoder().decode(TerminalCommandContextRequest.Response.self, from: Data(unknown.utf8)).context?.command == nil)
        let none = try JSONDecoder().decode(TerminalCommandContextRequest.Response.self, from: Data(#"{"context":null}"#.utf8))
        #expect(none.context == nil)
    }
}
