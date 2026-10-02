import Foundation
import Testing
@testable import CmuxNextDaemon

/// Wire shapes of terminal command history (`terminal-command-history-v1`,
/// cmux-tui/spec/commands.md): the switch with its retention, the list and
/// the delete.
@Suite struct TerminalCommandWireTests {
    private func object<R: DaemonRequest>(_ request: R) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func theSwitchCarriesTheRetention() throws {
        let set = try object(SetTerminalCommandHistoryRequest(enabled: true, retentionDays: 30))
        #expect(set["cmd"] == .string("set-terminal-command-history"))
        #expect(set["enabled"] == .bool(true))
        #expect(set["retention_days"] == .number(30))
        #expect(try object(SetTerminalCommandHistoryRequest(enabled: false))["retention_days"] == nil)
        let response = try WireCoding.decoder().decode(SetTerminalCommandHistoryRequest.Response.self,
                                                       from: Data(#"{"enabled":false,"retention_days":7}"#.utf8))
        #expect(response == .init(enabled: false, retentionDays: 7))
    }

    @Test func listDecodesRowsAndTheDeletionCounter() throws {
        let list = try object(ListTerminalCommandsRequest(afterID: "41", limit: 1_000))
        #expect(list["cmd"] == .string("list-terminal-commands"))
        #expect(list["after_id"] == .string("41") && list["limit"] == .number(1_000))
        #expect(try object(ListTerminalCommandsRequest())["after_id"] == nil)
        let json = """
        {"commands":[{"id":"42","terminal_id":"term_1","command":"make test","cwd":"/repo","exit_code":2,
                      "started_at_ms":"1000","duration_ms":"250"},
                     {"id":"43","terminal_id":"term_1","command":null,"cwd":null,"exit_code":null,
                      "started_at_ms":"2000","duration_ms":"0"}],
         "truncated":false,"deletions":"3","registry_id":"reg_1","retention_days":30}
        """
        let page = try WireCoding.decoder().decode(ListTerminalCommandsRequest.Response.self, from: Data(json.utf8))
        #expect(page.deletions == "3" && page.retentionDays == 30 && !page.truncated)
        #expect(page.version == "reg_1/3")
        #expect(page.commands.map(\.id) == ["42", "43"])
        let first = try #require(page.commands.first)
        #expect(first.terminalID == "term_1" && first.command == "make test" && first.cwd == "/repo" && first.exitCode == 2)
        #expect(first.startedAtMs == "1000" && first.durationMs == "250")
        #expect(page.commands[1].command == nil && page.commands[1].exitCode == nil)
    }

    @Test func deleteNamesExactlyOneSelection() throws {
        let ids = try object(DeleteTerminalCommandsRequest(.ids(["1", "2"])))
        #expect(ids["cmd"] == .string("delete-terminal-commands"))
        #expect(ids["ids"] == .array([.string("1"), .string("2")]))
        #expect(ids["all"] == nil && ids["started_since_ms"] == nil)
        let since = try object(DeleteTerminalCommandsRequest(.startedSince(Date(timeIntervalSince1970: 12.5))))
        #expect(since["started_since_ms"] == .string("12500") && since["ids"] == nil)
        let all = try object(DeleteTerminalCommandsRequest(.all))
        #expect(all["all"] == .bool(true) && all["ids"] == nil)
        let response = try WireCoding.decoder().decode(DeleteTerminalCommandsRequest.Response.self, from: Data(#"{"deleted":2}"#.utf8))
        #expect(response.deleted == 2)
    }
}
