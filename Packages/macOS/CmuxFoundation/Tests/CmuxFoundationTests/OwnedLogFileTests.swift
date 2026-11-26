import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct OwnedLogFileTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-owned-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    private func append(_ text: String, to path: String) -> Bool {
        guard let handle = OwnedLogFile(path: path).openForAppending() else {
            return false
        }
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data(text.utf8))
        return true
    }

    @Test func createsAPrivateFileAndAppends() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = path("app.log")
        #expect(append("one\n", to: log))
        #expect(append("two\n", to: log))
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "one\ntwo\n")
        var info = stat()
        #expect(lstat(log, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == geteuid())
    }

    @Test(arguments: [mode_t(0o644), mode_t(0o666)])
    func makesAnExistingLogPrivateBeforeReturningItsHandle(mode: mode_t) throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = path("existing.log")
        try "earlier\n".write(toFile: log, atomically: false, encoding: .utf8)
        try #require(chmod(log, mode) == 0)

        let handle = try #require(OwnedLogFile(path: log).openForAppending())
        defer { try? handle.close() }
        var info = stat()
        try #require(fstat(handle.fileDescriptor, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o600)
        try handle.write(contentsOf: Data("private diagnostic\n".utf8))
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "earlier\nprivate diagnostic\n")
    }

    @Test func doesNotWriteThroughASymlink() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = path("target")
        try "kept\n".write(toFile: target, atomically: false, encoding: .utf8)
        let log = path("linked.log")
        try FileManager.default.createSymbolicLink(atPath: log, withDestinationPath: target)
        #expect(!append("logged\n", to: log))
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "kept\n")
    }

    @Test func doesNotCreateASymlinkTarget() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = path("missing")
        let log = path("dangling.log")
        try FileManager.default.createSymbolicLink(atPath: log, withDestinationPath: target)
        #expect(!append("logged\n", to: log))
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func doesNotWriteThroughAHardLink() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = path("target")
        try "kept\n".write(toFile: target, atomically: false, encoding: .utf8)
        let log = path("hard.log")
        #expect(link(target, log) == 0)
        #expect(!append("logged\n", to: log))
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "kept\n")
    }

    @Test func doesNotWriteToAFileAnotherUserOwns() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = path("other.log")
        try "kept\n".write(toFile: log, atomically: false, encoding: .utf8)
        let otherUser = OwnedLogFile(path: log, owner: geteuid() &+ 1)
        #expect(otherUser.openForAppending() == nil)
        #expect(try String(contentsOfFile: log, encoding: .utf8) == "kept\n")
    }

    @Test func doesNotOpenADirectory() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = path("dir.log")
        try FileManager.default.createDirectory(atPath: log, withIntermediateDirectories: false)
        #expect(OwnedLogFile(path: log).openForAppending() == nil)
    }
}
