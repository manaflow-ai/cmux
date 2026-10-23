@testable import CmuxNextApp
import CmuxNextHistory
import Foundation
import Testing

/// The New Tab omnibar's command suggestions (`CommandHistory.recentTitles`). They used to be
/// the first 40 history entries of whichever machine's mirror came first: the oldest commands
/// (a mirror is oldest first), with a row that had no command text listed as "Unknown command".
/// They are the newest commands across every machine, newest first, and only ones with text.
@MainActor
struct NewTabCommandSuggestionsTests {
    private static func mirror(_ machine: String, _ rows: [(id: UInt64, command: String?, at: TimeInterval)]) -> TerminalCommandMirror {
        var mirror = TerminalCommandMirror(machine: machine)
        let commands = rows.map {
            TerminalCommand(id: $0.id, machine: machine, terminal: "t", command: $0.command, cwd: nil, exitCode: nil,
                            startedAt: Date(timeIntervalSince1970: $0.at), duration: nil)
        }
        _ = mirror.apply(commands, version: "v1", truncated: false, after: nil)
        return mirror
    }

    private static let local = mirror("local", [(1, "make", 10), (2, nil, 40), (3, "git status", 30), (4, "", 60), (5, "ls", 50)])
    private static let remote = mirror("cloud-1", [(1, "top", 20), (2, "htop", 45), (3, nil, 70)])

    @Test func newestFirstAcrossMachinesWithoutEmptyCommands() {
        #expect(CommandHistory.recentTitles(40, in: [Self.local, Self.remote]) == ["ls", "htop", "git status", "top", "make"])
        #expect(CommandHistory.recentTitles(40, in: [Self.remote, Self.local]) == ["ls", "htop", "git status", "top", "make"])
    }

    @Test func theLimitKeepsTheNewest() {
        #expect(CommandHistory.recentTitles(2, in: [Self.local, Self.remote]) == ["ls", "htop"])
        #expect(CommandHistory.recentTitles(0, in: [Self.local, Self.remote]).isEmpty)
    }
}
