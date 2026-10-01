import Darwin
import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct PrivateDirectoryCheckTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-private-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    private func makeDirectory(_ name: String, mode: mode_t) throws -> String {
        let path = path(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        #expect(chmod(path, mode) == 0)
        return path
    }

    private func mode(atPath path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode & 0o7777
    }

    @Test func tightensAnOwnedDirectory() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = try makeDirectory("shared", mode: 0o775)
        #expect(PrivateDirectoryCheck().makePrivate(atPath: shared))
        #expect(mode(atPath: shared) == 0o700)
    }

    @Test func rejectsASymlinkAndLeavesItsTarget() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = try makeDirectory("target", mode: 0o755)
        let link = path("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        #expect(!PrivateDirectoryCheck().makePrivate(atPath: link))
        #expect(mode(atPath: target) == 0o755)
    }

    @Test func rejectsADirectoryAnotherUserOwns() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let foreign = try makeDirectory("foreign", mode: 0o755)
        let check = PrivateDirectoryCheck(owner: geteuid() &+ 1)
        #expect(!check.makePrivate(atPath: foreign))
        #expect(mode(atPath: foreign) == 0o755)
    }

    @Test func rejectsARegularFile() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = path("file")
        try "kept\n".write(toFile: file, atomically: false, encoding: .utf8)
        #expect(chmod(file, 0o644) == 0)
        #expect(!PrivateDirectoryCheck().makePrivate(atPath: file))
        #expect(mode(atPath: file) == 0o644)
    }

    @Test func rejectsAMissingPath() {
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!PrivateDirectoryCheck().makePrivate(atPath: path("missing")))
    }

    @Test func rejectsARealDirectoryUnderANonStickySharedAncestor() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = path("shared")
        try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: false)
        #expect(chmod(shared, 0o777) == 0)
        let target = path("shared/target")
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
        #expect(chmod(target, 0o700) == 0)
        #expect(!PrivateDirectoryCheck().makePrivate(atPath: target))
        #expect(mode(atPath: target) == 0o700)
    }
}
