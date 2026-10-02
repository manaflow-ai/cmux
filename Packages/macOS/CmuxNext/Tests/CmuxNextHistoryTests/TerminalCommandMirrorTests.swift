import CmuxNextHistory
import Foundation
import Testing

/// One machine's terminal commands as read with `list-terminal-commands`
/// (`terminal-command-history-v1`): pages append after the last id until
/// the daemon reports a delete or a gap, then the next read starts over.
struct TerminalCommandMirrorTests {
    static func command(_ id: UInt64, _ text: String? = nil, started: TimeInterval? = nil) -> TerminalCommand {
        TerminalCommand(id: id, machine: "local", terminal: "term_1", command: text ?? "c\(id)", cwd: "/repo", exitCode: 0,
                        startedAt: Date(timeIntervalSince1970: started ?? TimeInterval(id)), duration: 0.25)
    }

    @Test func pagesAppendAfterTheLastID() {
        var mirror = TerminalCommandMirror(machine: "local")
        #expect(mirror.cursor == nil, "the first read starts at the beginning")
        let applied1 = mirror.apply([Self.command(1), Self.command(2)], version: "r/0", truncated: false, after: nil)
        #expect(applied1)
        #expect(mirror.cursor == 2)
        let applied2 = mirror.apply([Self.command(3)], version: "r/0", truncated: false, after: 2)
        #expect(applied2)
        #expect(mirror.commands.map(\.id) == [1, 2, 3])
        let applied3 = mirror.apply([], version: "r/0", truncated: false, after: 3)
        #expect(applied3)
        #expect(mirror.cursor == 3)
        #expect(mirror.commands.first?.qualifiedID == "local/1")
    }

    @Test func aDeleteSinceTheLastReadStartsOver() {
        var mirror = TerminalCommandMirror(machine: "local")
        let applied4 = mirror.apply([Self.command(1), Self.command(2)], version: "r/0", truncated: false, after: nil)
        #expect(applied4)
        let applied5 = mirror.apply([Self.command(3)], version: "r/1", truncated: false, after: 2)
        #expect(!applied5, "rows were deleted: read again")
        #expect(mirror.cursor == nil && mirror.commands.isEmpty)
        let applied6 = mirror.apply([Self.command(2), Self.command(3)], version: "r/1", truncated: false, after: nil)
        #expect(applied6)
        #expect(mirror.commands.map(\.id) == [2, 3] && mirror.cursor == 3)
    }

    @Test func keepsTheNewestCommandsUpToItsCapacity() {
        var mirror = TerminalCommandMirror(machine: "local", capacity: 2)
        let applied7 = mirror.apply((1...5).map { Self.command($0) }, version: "r/0", truncated: false, after: nil)
        #expect(applied7)
        #expect(mirror.commands.map(\.id) == [4, 5])
        #expect(mirror.cursor == 5)
    }

    @Test func removesLocallyByIDAndByStartTime() {
        var mirror = TerminalCommandMirror(machine: "local")
        let applied8 = mirror.apply((1...4).map { Self.command($0, started: TimeInterval($0) * 100) }, version: "r/0", truncated: false, after: nil)
        #expect(applied8)
        mirror.remove(ids: [2])
        #expect(mirror.commands.map(\.id) == [1, 3, 4])
        mirror.remove(startedSince: Date(timeIntervalSince1970: 300))
        #expect(mirror.commands.map(\.id) == [1])
        mirror.remove(startedSince: nil)
        #expect(mirror.commands.isEmpty)
    }

    @Test func aTruncatedReadAfterTheCursorStartsOver() {
        var mirror = TerminalCommandMirror(machine: "local")
        let first = mirror.apply([Self.command(1)], version: "r/0", truncated: false, after: nil)
        #expect(first)
        let gap = mirror.apply([Self.command(5)], version: "r/0", truncated: true, after: 1)
        #expect(!gap, "rows 2...4 were left out")
        #expect(mirror.cursor == nil && mirror.commands.isEmpty)
        let full = mirror.apply([Self.command(4), Self.command(5)], version: "r/0", truncated: true, after: nil)
        #expect(full, "a read from the beginning keeps the newest rows")
        #expect(mirror.commands.map(\.id) == [4, 5])
    }

    @Test func anotherRegistryStartsOver() {
        var mirror = TerminalCommandMirror(machine: "local")
        let first = mirror.apply([Self.command(7)], version: "a/0", truncated: false, after: nil)
        #expect(first)
        let other = mirror.apply([Self.command(1)], version: "b/0", truncated: false, after: 7)
        #expect(!other)
    }

    @Test func dropsExpiredRows() {
        var mirror = TerminalCommandMirror(machine: "local")
        let first = mirror.apply((1...3).map { Self.command($0, started: TimeInterval($0) * 100) }, version: "r/0", truncated: false,
                                 after: nil, expiredThrough: Date(timeIntervalSince1970: 200))
        #expect(first)
        #expect(mirror.commands.map(\.id) == [3])
        #expect(mirror.cursor == 3)
    }
}
