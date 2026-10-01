import Foundation
import Testing
@testable import CmuxNextDaemon

/// Per-terminal themes in the home session's personal state
/// (`personal-terminals-v1`).
@MainActor @Suite struct PersonalTerminalThemeTests {
    @Test func listPersonalDecodesTerminalThemesAndOlderServersOmitThem() throws {
        let json = #"{"personal_revision":3,"terminals":[{"session_id":"s1","terminal_key":"term_1","theme":"Nord"}]}"#
        let state = try JSONDecoder().decode(PersonalState.self, from: Data(json.utf8))
        #expect(state.terminals == [PersonalTerminal(sessionID: "s1", terminalKey: "term_1", theme: "Nord")])
        let older = try JSONDecoder().decode(PersonalState.self, from: Data(#"{"personal_revision":1}"#.utf8))
        #expect(older.terminals.isEmpty)
    }

    @Test func setPersonalTerminalSendsNullToClear() throws {
        let set = try JSONEncoder().encode(SetPersonalTerminalRequest(sessionID: "s1", terminalKey: "term_1", theme: "Nord"))
        let clear = try JSONEncoder().encode(SetPersonalTerminalRequest(sessionID: "s1", terminalKey: "term_1", theme: nil))
        let setObject = try JSONSerialization.jsonObject(with: set) as? [String: Any]
        let clearObject = try JSONSerialization.jsonObject(with: clear) as? [String: Any]
        #expect(setObject?["theme"] as? String == "Nord")
        #expect(clearObject?["theme"] is NSNull)
        #expect(clearObject?["terminal_key"] as? String == "term_1")
        #expect(SetPersonalTerminalRequest.command == "set-personal-terminal")
    }
}
