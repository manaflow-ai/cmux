import Foundation
import Testing
@testable import CmuxNextCrashReporting

/// p09-observability-084: the `FATAL` line Chromium wrote before it aborted the process that ran `CefInitialize`
/// becomes the `cef.fatal` tag: `FATAL:<path>:<line>]` plus 120 characters, every URL removed.
@Suite struct CEFFatalLineTests {
    private static let pid: Int32 = 4242

    private static func line(pid: Int32 = Self.pid, severity: String = "FATAL", location: String = "content/browser/a.cc:42",
                             _ message: String) -> String {
        "[\(pid):259:1027/101010.123456:\(severity):\(location)] \(message)"
    }

    @Test func keepsTheLocationAndTheMessage() throws {
        let line = try #require(CEFFatalLine(log: Self.line("Check failed: frame_tree_node. ")))
        #expect(line.path == "content/browser/a.cc")
        #expect(line.line == 42)
        #expect(line.tagValue == "FATAL:content/browser/a.cc:42] Check failed: frame_tree_node. ")
    }

    /// Older Chromium prints `path(line)`; the tag always says `path:line`, with no leading `../`.
    @Test func readsTheOlderLocationForm() throws {
        let line = try #require(CEFFatalLine(log: Self.line(location: "../../base/x.cc(7)", "boom")))
        #expect(line.tagValue == "FATAL:base/x.cc:7] boom")
    }

    @Test func plantedURLLinesAreRedacted() throws {
        let planted = [
            "https://bank.example.com/account?id=1234",
            "http://intranet.corp.test/secret",
            "chrome-extension://abcdefghijklmnop/popup.html",
            "file:///Users/alice/Documents/private.pdf",
            "data:text/html,<b>secret</b>",
            "javascript:alert(document.cookie)",
            "blob:https://drive.example.com/uuid",
            "www.example.org/path",
            "(url=\"https://quoted.example.net/q\")",
            "about:blank#secret",
        ]
        for url in planted {
            let line = try #require(CEFFatalLine(log: Self.line("Check failed: navigation to \(url) committed")))
            #expect(line.message.contains("<url>"), "\(url)")
            for secret in ["example", "corp.test", "abcdefghij", "alice", "secret", "cookie", "://"] {
                #expect(!line.tagValue.contains(secret), "\(url) left \(secret) in \(line.tagValue)")
            }
            #expect(line.tagValue.hasPrefix("FATAL:content/browser/a.cc:42] Check failed: navigation to "))
        }
    }

    /// The URL goes before the message is cut, so a URL that crosses character 120 leaves no part of itself.
    @Test func aURLAcrossTheCutLeavesNothing() throws {
        let padding = String(repeating: "x ", count: 55)
        let line = try #require(CEFFatalLine(log: Self.line(padding + "https://late.example.com/a/b/c/d/e/f")))
        #expect(line.message.count <= CEFFatalLine.maxMessageCharacters)
        #expect(!line.message.contains("late"))
        #expect(!line.message.contains("http"))
    }

    @Test func keepsAtMost120MessageCharactersAndATagSentryKeeps() throws {
        let path = String(repeating: "deep/", count: 30) + "file.cc"
        let line = try #require(CEFFatalLine(log: Self.line(location: "\(path):123456", String(repeating: "m", count: 500))))
        #expect(line.message.count == CEFFatalLine.maxMessageCharacters)
        #expect(line.path.count == CEFFatalLine.maxPathCharacters)
        #expect(line.path.hasSuffix("file.cc"))
        #expect(line.tagValue.count <= 200)
    }

    /// The last `FATAL` is the one that ended the process; other severities, and a message that only mentions
    /// `:FATAL:`, are not.
    @Test func takesTheLastFatalLine() throws {
        let log = [
            Self.line("first fatal"),
            Self.line(severity: "ERROR", "the page said :FATAL:x.cc:1] fake"),
            Self.line(location: "gpu/b.cc:9", "second fatal"),
            Self.line(severity: "WARNING", "after"),
            "    #0 0x1234 base::debug::StackTrace::StackTrace()",
        ].joined(separator: "\n")
        let line = try #require(CEFFatalLine(log: log))
        #expect(line.tagValue == "FATAL:gpu/b.cc:9] second fatal")
        #expect(CEFFatalLine(log: Self.line(severity: "ERROR", "only an error")) == nil)
        #expect(CEFFatalLine(log: "") == nil)
    }

    /// Helpers write to the same log: a renderer's `FATAL` is not the browser process's.
    @Test func skipsAnotherProcesssLine() throws {
        let log = [Self.line(location: "content/browser/own.cc:1", "browser abort"),
                   Self.line(pid: 777, location: "content/renderer/r.cc:2", "renderer abort")].joined(separator: "\n")
        #expect(try #require(CEFFatalLine(log: log, pid: Self.pid)).path == "content/browser/own.cc")
        #expect(CEFFatalLine(log: Self.line(pid: 777, "renderer abort"), pid: Self.pid) == nil)
        // No pid field in the prefix: the line is taken.
        #expect(CEFFatalLine(log: "[FATAL:a.cc:3] bare", pid: Self.pid)?.tagValue == "FATAL:a.cc:3] bare")
    }

    @Test func readsOnlyTheLast64KiB() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "cef.log")
        let filler = String(repeating: Self.line(severity: "WARNING", "filler") + "\n", count: 1_000)
        // An abort far before the tail is not read; one in the tail is.
        try Data((Self.line(location: "old.cc:1", "too early") + "\n" + filler).utf8).write(to: file)
        #expect(CEFFatalLine.read(candidates: [file], writtenIn: Self.always, pid: Self.pid) == nil)
        try Data((filler + Self.line(location: "late.cc:2", "in the tail") + "\n").utf8).write(to: file)
        #expect(CEFFatalLine.read(candidates: [file], writtenIn: Self.always, pid: Self.pid)?.path == "late.cc")
        let tail = try #require(CEFFatalLine.tail(of: file))
        #expect(tail.utf8.count <= CEFFatalLine.maxTailBytes)
        #expect(tail.hasPrefix("["), "the partial first line is dropped")
    }

    /// Only a file last written in the window counts, and the newest of those.
    @Test func readsTheNewestFileWrittenInTheWindow() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = directory.appending(path: "cef.previous.log")
        let newer = directory.appending(path: "cef.log")
        try Data(Self.line(location: "older.cc:1", "x").utf8).write(to: older)
        try Data(Self.line(location: "newer.cc:1", "x").utf8).write(to: newer)
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        try Self.touch(older, base.addingTimeInterval(10))
        try Self.touch(newer, base.addingTimeInterval(20))
        #expect(CEFFatalLine.read(candidates: [older, newer], writtenIn: base ..< base.addingTimeInterval(30), pid: Self.pid)?.path
            == "newer.cc")
        #expect(CEFFatalLine.read(candidates: [older, newer], writtenIn: base ..< base.addingTimeInterval(15), pid: Self.pid)?.path
            == "older.cc")
        #expect(CEFFatalLine.read(candidates: [older, newer], writtenIn: base.addingTimeInterval(25) ..< base.addingTimeInterval(30),
                                  pid: Self.pid) == nil)
        #expect(CEFFatalLine.read(candidates: [directory.appending(path: "missing.log")], writtenIn: Self.always, pid: Self.pid) == nil)
    }

    private static let always = Date.distantPast ..< Date.distantFuture

    private static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cef-fatal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func touch(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
