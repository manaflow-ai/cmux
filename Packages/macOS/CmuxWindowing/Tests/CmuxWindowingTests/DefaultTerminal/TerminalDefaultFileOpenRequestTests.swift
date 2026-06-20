import Foundation
import Testing
@testable import CmuxWindowing

@Suite("TerminalDefaultFileOpenRequest")
struct TerminalDefaultFileOpenRequestTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-file-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("rejects a non-file URL")
    func rejectsNonFileURL() {
        let url = URL(string: "https://example.com/run.command")!
        #expect(TerminalDefaultFileOpenRequest(fileURL: url) == nil)
    }

    @Test("rejects a directory")
    func rejectsDirectory() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(TerminalDefaultFileOpenRequest(fileURL: dir) == nil)
    }

    @Test("accepts a .command file and builds working dir + shell-quoted input")
    func acceptsCommandFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("run it.command")
        try "echo hi".write(to: file, atomically: true, encoding: .utf8)

        let request = try #require(TerminalDefaultFileOpenRequest(fileURL: file))
        #expect(request.workingDirectory == dir.standardizedFileURL.path(percentEncoded: false))
        let expectedPath = file.standardizedFileURL.path(percentEncoded: false)
        #expect(request.initialInput == "'\(expectedPath)'\n")
    }

    @Test("rejects a plain non-executable text file")
    func rejectsPlainTextFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        #expect(TerminalDefaultFileOpenRequest(fileURL: file) == nil)
    }

    @Test("accepts an executable file without a terminal content type")
    func acceptsExecutableFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("tool.bin")
        try "#!/bin/sh\necho hi\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        #expect(TerminalDefaultFileOpenRequest(fileURL: file) != nil)
    }

    @Test("requests(from:) de-duplicates by path and preserves order")
    func requestsDeduplicate() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.command")
        let b = dir.appendingPathComponent("b.command")
        try "x".write(to: a, atomically: true, encoding: .utf8)
        try "y".write(to: b, atomically: true, encoding: .utf8)

        let requests = TerminalDefaultFileOpenRequest.requests(from: [a, b, a])
        #expect(requests.count == 2)
        #expect(requests[0].fileURL.lastPathComponent == "a.command")
        #expect(requests[1].fileURL.lastPathComponent == "b.command")
    }
}
