import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHistory
import CmuxNextHistoryDaemon
import Foundation
import Observation
import Testing

/// cmux#38186 review: a command deletion the daemon refuses brings its rows back on the next read (the mirror's cursor
/// resets, so that read starts from the first row) while every other pending deletion still applies; and a read applies
/// its page to the mirror as it is when the page arrives, so a deletion made or refused during the request holds.
@MainActor @Suite(.serialized) struct CommandHistoryReadTests {
    @MainActor @Observable final class Link {
        var up = true
    }

    /// A remote's direct `delete-terminal-commands`: refuses the ids in `refused`, holds the ids in `holds` until ``release()``.
    @MainActor final class Deletes {
        var refused: Set<String> = []
        var holds: Set<String> = []
        var sent: [DeleteTerminalCommandsRequest.Selection] = []
        var held: [CheckedContinuation<Void, Never>] = []

        func delete(_ selection: DeleteTerminalCommandsRequest.Selection) async throws {
            sent.append(selection)
            guard case .ids(let ids) = selection else { return }
            if ids.contains(where: refused.contains) {
                throw DaemonError.command(cmd: "delete-terminal-commands", message: "refused", code: nil)
            }
            if ids.contains(where: holds.contains) { await withCheckedContinuation { held.append($0) } }
        }

        func release() {
            let waiting = held
            held = []
            for waiter in waiting { waiter.resume() }
        }
    }

    static let remote = "ssh-box"

    static func rows(_ ids: [UInt64]) -> [TerminalCommand] {
        ids.map { TerminalCommand(id: $0, machine: remote, terminal: "term_1", command: "cmd \($0)", cwd: nil, exitCode: 0,
                                  startedAt: Date().addingTimeInterval(-60), duration: 1) }
    }

    /// A `list-terminal-commands` page holding `rows`, at version `r1/0`.
    static func page(_ rows: [TerminalCommand]) throws -> ListTerminalCommandsRequest.Response {
        let commands: [[String: Any]] = rows.map {
            ["id": String($0.id), "terminal_id": $0.terminal, "command": $0.command ?? "",
             "started_at_ms": String(Int64($0.startedAt.timeIntervalSince1970 * 1000)), "duration_ms": "1000"]
        }
        let json: [String: Any] = ["commands": commands, "truncated": false, "deletions": "0", "registry_id": "r1", "retention_days": 30]
        return try JSONDecoder().decode(ListTerminalCommandsRequest.Response.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func services(seeded rows: [TerminalCommand]) -> AppServices {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        var mirror = TerminalCommandMirror(machine: remote)
        let applied = mirror.apply(rows, version: "r1/0", truncated: false, after: nil)
        #expect(applied)
        services.history.commands.mirrors[remote] = mirror
        return services
    }

    /// F1: the refused removal's row lists again on the next read (a full one), the removal still waiting stays out.
    @Test func aRefusedRemovalComesBackOnTheNextReadAndAPendingOneStaysOut() async throws {
        let rows = Self.rows([3, 4, 5])
        let services = Self.services(seeded: rows)
        let commands = services.history.commands
        let remote = Self.remote
        let deletes = Deletes()
        deletes.refused = ["3"]
        deletes.holds = ["4"]
        commands.route = { $0 == remote ? .direct { try await deletes.delete($0) } : nil }
        commands.delete(rows[0])
        commands.delete(rows[1])
        #expect(commands.mirrors[remote]?.commands.map(\.id) == [5])
        for _ in 0..<1_000 where deletes.held.isEmpty { await Task.yield() }
        #expect(deletes.sent == [.ids(["3"]), .ids(["4"])])
        let refused = try #require(commands.mirrors[remote])
        #expect(refused.cursor == nil, "the refused removal kept the cursor, so no later read brings its row back")
        #expect(refused.pending.count == 1, "the refusal dropped the other removal's filter, or kept its own")
        var asked: [UInt64?] = []
        try await commands.read(remote) { after in
            asked.append(after)
            return try Self.page(rows)
        }
        #expect(asked == [nil], "the read after a refusal was not a full one")
        #expect(commands.mirrors[remote]?.commands.map(\.id) == [3, 5], "the refused row stayed out, or the pending one came back")
        deletes.release()
        for _ in 0..<1_000 where commands.mirrors[remote]?.pending.isEmpty == false { await Task.yield() }
        #expect(commands.mirrors[remote]?.pending.isEmpty == true)
    }

    /// F2: a removal made while a read is out stays applied when the page arrives; the read does not write back the
    /// mirror it started from.
    @Test func aRemovalMadeDuringAReadStaysOut() async throws {
        let rows = Self.rows([3, 4])
        let services = Self.services(seeded: rows)
        let commands = services.history.commands
        let remote = Self.remote
        let link = Link()
        link.up = false
        let deletes = Deletes()
        commands.route = { $0 == remote && link.up ? .direct { try await deletes.delete($0) } : nil }
        var asked: [UInt64?] = []
        try await commands.read(remote) { after in
            asked.append(after)
            commands.delete(rows[0])
            return try Self.page([])
        }
        #expect(asked == [4])
        let read = try #require(commands.mirrors[remote])
        #expect(read.commands.map(\.id) == [4], "the read brought back a row removed while it was out")
        #expect(read.pending.count == 1, "the read dropped the pending removal")
        link.up = true
        for _ in 0..<1_000 where commands.mirrors[remote]?.pending.isEmpty == false { await Task.yield() }
        #expect(deletes.sent == [.ids(["3"])])
    }

    /// F2: a removal refused while a read is out resets the cursor under it: the page read after the old cursor is not
    /// appended; the read goes again from the first row and lists the refused row.
    @Test func aRemovalRefusedDuringAReadIsReadAgainInFull() async throws {
        let rows = Self.rows([3, 4, 5])
        let services = Self.services(seeded: rows)
        let commands = services.history.commands
        let remote = Self.remote
        let link = Link()
        link.up = false
        let deletes = Deletes()
        deletes.refused = ["3"]
        commands.route = { $0 == remote && link.up ? .direct { try await deletes.delete($0) } : nil }
        commands.delete(rows[0])
        var asked: [UInt64?] = []
        try await commands.read(remote) { after in
            asked.append(after)
            guard after != nil else { return try Self.page(rows) }
            link.up = true
            for _ in 0..<1_000 where commands.mirrors[remote]?.pending.isEmpty == false { await Task.yield() }
            return try Self.page([])
        }
        #expect(deletes.sent == [.ids(["3"])])
        #expect(asked == [5, nil], "the page read after the old cursor was appended to a reset mirror")
        #expect(commands.mirrors[remote]?.commands.map(\.id) == [3, 4, 5])
    }
}
