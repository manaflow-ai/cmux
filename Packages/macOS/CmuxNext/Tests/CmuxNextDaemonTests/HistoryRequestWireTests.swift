import Foundation
import Testing
@testable import CmuxNextDaemon

/// Exercise the app's encoder/decoder, including its snake-case strategy and request envelope.
struct HistoryRequestWireTests {
    private func line(_ request: some DaemonRequest) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 7))
    }

    private func envelope(_ command: String, _ fields: [String: JSONValue] = [:]) -> JSONValue {
        .object(fields.merging(["id": .number(7), "cmd": .string(command)]) { $1 })
    }

    @Test func listOmitsAbsentOptionsAndPreservesDecimalCursor() throws {
        #expect(try line(ListTerminalCommandsRequest()) == envelope("list-terminal-commands"))
        #expect(try line(ListTerminalCommandsRequest(afterID: "18446744073709551615", limit: 25)) ==
            envelope("list-terminal-commands", ["after_id": .string("18446744073709551615"), "limit": .number(25)]))
        #expect(try line(ListTerminalCommandsRequest(limit: 0)) ==
            envelope("list-terminal-commands", ["limit": .number(0)]))
    }

    @Test(arguments: [false, true])
    func settingsAlwaysSendsEnabledAndOnlyExplicitRetention(enabled: Bool) throws {
        #expect(try line(SetTerminalCommandHistoryRequest(enabled: enabled)) ==
            envelope("set-terminal-command-history", ["enabled": .bool(enabled)]))
        #expect(try line(SetTerminalCommandHistoryRequest(enabled: enabled, retentionDays: 30)) ==
            envelope("set-terminal-command-history", ["enabled": .bool(enabled), "retention_days": .number(30)]))
    }

    @Test func deleteIDsAndAllRemainExclusive() throws {
        #expect(try line(DeleteTerminalCommandsRequest(.ids(["1", "18446744073709551615"]))) ==
            envelope("delete-terminal-commands", ["ids": .array([.string("1"), .string("18446744073709551615")])]))
        // Preserve daemon validation: an empty selection must never turn into delete-all.
        #expect(try line(DeleteTerminalCommandsRequest(.ids([]))) ==
            envelope("delete-terminal-commands", ["ids": .array([])]))
        #expect(try line(DeleteTerminalCommandsRequest(.all)) ==
            envelope("delete-terminal-commands", ["all": .bool(true)]))
    }

    @Test(arguments: [(-1.0, "0"), (0.0, "0"), (1.2344, "1234"), (1.2346, "1235"), (1.0e30, "18446744073709551615")])
    func deleteSinceRoundsAndClampsWithoutAddingOtherSelectors(seconds: Double, milliseconds: String) throws {
        #expect(try line(DeleteTerminalCommandsRequest(.startedSince(Date(timeIntervalSince1970: seconds)))) ==
            envelope("delete-terminal-commands", ["started_since_ms": .string(milliseconds)]))
    }

    @Test func listResponsePreservesRowsNullsAndRefreshVersion() throws {
        let wire = #"{"id":7,"ok":true,"data":{"commands":[{"id":"18446744073709551615","terminal_id":"term-test","command":"echo test","cwd":"/tmp","exit_code":-1,"started_at_ms":"9007199254740993","duration_ms":"18446744073709551615"},{"id":"2","terminal_id":"term-test","command":null,"cwd":null,"exit_code":null,"started_at_ms":"1","duration_ms":"0"}],"truncated":true,"deletions":"9007199254740993","registry_id":"registry-test","retention_days":30}}"#
        let response = try WireCoding.decodeResponse(ListTerminalCommandsRequest.Response.self, from: Data(wire.utf8))
        #expect(response.truncated)
        #expect(response.version == "registry-test/9007199254740993")
        #expect(response.retentionDays == 30)
        #expect(response.commands.count == 2)
        let completed = try #require(response.commands.first)
        #expect(completed.id == "18446744073709551615")
        #expect(completed.terminalID == "term-test")
        #expect(completed.command == "echo test")
        #expect(completed.cwd == "/tmp")
        #expect(completed.exitCode == -1)
        #expect(completed.startedAtMs == "9007199254740993")
        #expect(completed.durationMs == "18446744073709551615")
        let running = try #require(response.commands.last)
        #expect(running.cwd == nil)
        #expect(running.exitCode == nil)
        #expect(running.command == nil)
        #expect(running.durationMs == "0")
    }

    @Test func settingsAndDeleteResponsesDecodeThroughTheEnvelope() throws {
        let settings = try WireCoding.decodeResponse(SetTerminalCommandHistoryRequest.Response.self,
            from: Data(#"{"id":7,"ok":true,"data":{"enabled":false,"retention_days":90}}"#.utf8))
        #expect(settings == SetTerminalCommandHistoryResponse(enabled: false, retentionDays: 90))
        let deleted = try WireCoding.decodeResponse(DeleteTerminalCommandsRequest.Response.self,
            from: Data(#"{"id":7,"ok":true,"data":{"deleted":18446744073709551615}}"#.utf8))
        #expect(deleted.deleted == UInt64.max)
    }
}
