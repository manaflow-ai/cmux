import CmuxNextHistory
import Foundation
import Testing

struct TerminalCommandFoldTests {
    static func record(_ sequence: Int, command: String?, exit: Int?, started: Int64 = 1_000, kind: String = "shell.command.finished") throws -> CommandJournalRecord {
        let commandJSON = command.map { "\"\($0)\"" } ?? "null"
        let exitJSON = exit.map(String.init) ?? "null"
        let json = """
        {"sequence":"\(sequence)","kind":"\(kind)","subjects":[{"kind":"terminal","id":"term_1"},{"kind":"workspace","id":"ws_1"}],
         "payload":{"command":\(commandJSON),"cwd":"/repo","exit_code":\(exitJSON),"started_at_ms":"\(started)","duration_ms":"250"}}
        """
        return try JSONDecoder().decode(CommandJournalRecord.self, from: Data(json.utf8))
    }

    @Test func foldsFinishedCommandsOnceInOrder() throws {
        var fold = TerminalCommandFold(machine: "local")
        let records = [try Self.record(1, command: "make", exit: 0), try Self.record(2, command: nil, exit: nil, started: 2_000)]
        fold.apply(records)
        fold.apply(records)
        #expect(fold.commands.count == 2)
        let first = try #require(fold.commands.first)
        #expect(first.command == "make" && first.cwd == "/repo" && first.exitCode == 0 && first.terminal == "term_1")
        #expect(first.startedAt == Date(timeIntervalSince1970: 1) && first.duration == 0.25)
        #expect(first.qualifiedID == "local/term_1/1000")
        #expect(fold.commands[1].command == nil && fold.commands[1].exitCode == nil)
        #expect(fold.cursor == 2)
    }

    @Test func otherKindsAdvanceTheCursorOnly() throws {
        var fold = TerminalCommandFold(machine: "local", capacity: 2)
        fold.apply([try Self.record(1, command: "x", exit: 0, kind: "agent.turn.started")])
        #expect(fold.commands.isEmpty && fold.cursor == 1)
        fold.apply((2...5).map { try! Self.record($0, command: "c\($0)", exit: 0, started: Int64($0) * 1000) })
        #expect(fold.commands.map(\.command) == ["c4", "c5"])
    }
}
