import Foundation
import Testing

@testable import CmuxBrowser

/// `fs` operations on symbolic links and on existing destinations, run
/// through `BrowserReplFileSystem.perform` on real temporary directories.
///
/// Acting on a link (`rm`, `rename`, `lstat`) checks only the link's parent
/// directory, as Node does; reading or writing through a link checks where
/// the link points.
@Suite("Browser REPL fs operations")
struct BrowserReplFileSystemTests {
    private typealias Scratch = BrowserReplFileSandboxTests.Scratch

    private let fileManager = FileManager.default

    /// An fs rooted at `work/`, with the temporary root moved off the real
    /// temporary directory (the scratch tree lives there).
    private func makeFileSystem(_ scratch: Scratch) -> BrowserReplFileSystem {
        BrowserReplFileSystem(
            sandbox: BrowserReplFileSandbox(root: scratch.root),
            temporaryDirectory: scratch.base + "/tmp"
        )
    }

    private func write(_ text: String, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    private func contents(_ path: String) -> String? {
        fileManager.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    private func linkDestination(_ path: String) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: path)
    }

    @Test("rm of a link to a file outside the root removes the link and keeps the file")
    func removeLinkToOutsideFile() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let secret = scratch.outside + "/secret.txt"
        try fileManager.createSymbolicLink(atPath: scratch.root + "/link", withDestinationPath: secret)
        let fs = makeFileSystem(scratch)

        let result = fs.perform("rm", arguments: ["path": "link"])

        #expect(result.failure == nil)
        #expect(linkDestination(scratch.root + "/link") == nil)
        #expect(contents(secret) == "secret")
    }

    @Test("rm -r of a link to a directory removes the link and keeps the directory's files")
    func removeLinkToDirectoryRecursively() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try fileManager.createDirectory(atPath: scratch.root + "/data", withIntermediateDirectories: true)
        try write("keep", to: scratch.root + "/data/keep.txt")
        try fileManager.createSymbolicLink(atPath: scratch.root + "/alias", withDestinationPath: scratch.root + "/data")
        let fs = makeFileSystem(scratch)

        let result = fs.perform("rm", arguments: ["path": "alias", "recursive": true])

        #expect(result.failure == nil)
        #expect(linkDestination(scratch.root + "/alias") == nil)
        #expect(contents(scratch.root + "/data/keep.txt") == "keep")
    }

    @Test("rm of a dangling link removes the link")
    func removeDanglingLink() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try fileManager.createSymbolicLink(
            atPath: scratch.root + "/dangling",
            withDestinationPath: scratch.outside + "/missing.txt"
        )
        let fs = makeFileSystem(scratch)

        let result = fs.perform("rm", arguments: ["path": "dangling"])

        #expect(result.failure == nil)
        #expect(linkDestination(scratch.root + "/dangling") == nil)
        #expect(!fileManager.fileExists(atPath: scratch.outside + "/missing.txt"))
    }

    @Test("rename of a link moves the link itself, whether it points inside or outside the root")
    func renameMovesTheLink() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let secret = scratch.outside + "/secret.txt"
        try write("inside", to: scratch.root + "/target.txt")
        try fileManager.createSymbolicLink(atPath: scratch.root + "/out-link", withDestinationPath: secret)
        try fileManager.createSymbolicLink(atPath: scratch.root + "/in-link", withDestinationPath: scratch.root + "/target.txt")
        let fs = makeFileSystem(scratch)

        let outside = fs.perform("rename", arguments: ["from": "out-link", "to": "out-moved"])
        let inside = fs.perform("rename", arguments: ["from": "in-link", "to": "in-moved"])

        #expect(outside.failure == nil)
        #expect(linkDestination(scratch.root + "/out-link") == nil)
        #expect(linkDestination(scratch.root + "/out-moved") == secret)
        #expect(contents(secret) == "secret")
        #expect(inside.failure == nil)
        #expect(linkDestination(scratch.root + "/in-link") == nil)
        #expect(linkDestination(scratch.root + "/in-moved") == scratch.root + "/target.txt")
        #expect(contents(scratch.root + "/target.txt") == "inside")
    }

    @Test("rename from a missing source fails with ENOENT and keeps the destination")
    func renameOfMissingSourceKeepsDestination() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try write("old", to: scratch.root + "/dest.txt")
        let fs = makeFileSystem(scratch)

        let result = fs.perform("rename", arguments: ["from": "missing.txt", "to": "dest.txt"])

        #expect(result.failure?.code == "ENOENT")
        #expect(contents(scratch.root + "/dest.txt") == "old")
    }

    @Test("rename replaces an existing destination file")
    func renameReplacesDestination() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try write("new", to: scratch.root + "/src.txt")
        try write("old", to: scratch.root + "/dest.txt")
        let fs = makeFileSystem(scratch)

        let result = fs.perform("rename", arguments: ["from": "src.txt", "to": "dest.txt"])

        #expect(result.failure == nil)
        #expect(contents(scratch.root + "/dest.txt") == "new")
        #expect(!fileManager.fileExists(atPath: scratch.root + "/src.txt"))
    }

    @Test("copyFile that fails keeps the existing destination and leaves no temporary file")
    func failedCopyKeepsDestination() throws {
        let scratch = try Scratch()
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scratch.root + "/unreadable.txt")
            scratch.remove()
        }
        try write("new", to: scratch.root + "/unreadable.txt")
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: scratch.root + "/unreadable.txt")
        try write("old", to: scratch.root + "/dest.txt")
        let fs = makeFileSystem(scratch)

        let result = fs.perform("copyFile", arguments: ["from": "unreadable.txt", "to": "dest.txt"])

        #expect(result.failure?.code == "EACCES")
        #expect(contents(scratch.root + "/dest.txt") == "old")
        #expect(try fileManager.contentsOfDirectory(atPath: scratch.root).sorted() == ["dest.txt", "unreadable.txt"])
    }

    @Test("copyFile replaces an existing destination")
    func copyReplacesDestination() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try write("new", to: scratch.root + "/src.txt")
        try write("old", to: scratch.root + "/dest.txt")
        let fs = makeFileSystem(scratch)

        let result = fs.perform("copyFile", arguments: ["from": "src.txt", "to": "dest.txt"])

        #expect(result.failure == nil)
        #expect(contents(scratch.root + "/dest.txt") == "new")
        #expect(contents(scratch.root + "/src.txt") == "new")
    }

    @Test("lstat and readdir describe a link as a link; stat describes its target")
    func linkTypes() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try write("inside", to: scratch.root + "/target.txt")
        try fileManager.createSymbolicLink(atPath: scratch.root + "/in-link", withDestinationPath: scratch.root + "/target.txt")
        try fileManager.createSymbolicLink(atPath: scratch.root + "/out-link", withDestinationPath: scratch.outside + "/secret.txt")
        let fs = makeFileSystem(scratch)

        #expect(fs.perform("lstat", arguments: ["path": "in-link"]).type == "symlink")
        #expect(fs.perform("lstat", arguments: ["path": "out-link"]).type == "symlink")
        #expect(fs.perform("stat", arguments: ["path": "in-link"]).type == "file")
        let entries = try fs.perform("readdir", arguments: ["path": "."]).get() as? [[String: Any]]
        let types = Dictionary(uniqueKeysWithValues: (entries ?? []).compactMap { entry -> (String, String)? in
            guard let name = entry["name"] as? String, let type = entry["type"] as? String else { return nil }
            return (name, type)
        })
        #expect(types == ["in-link": "symlink", "out-link": "symlink", "target.txt": "file"])
    }

    @Test("Reading or writing through a link to outside the root is still refused")
    func throughLinkStaysConfined() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let secret = scratch.outside + "/secret.txt"
        try fileManager.createSymbolicLink(atPath: scratch.root + "/out-link", withDestinationPath: secret)
        try fileManager.createSymbolicLink(atPath: scratch.root + "/out-dir", withDestinationPath: scratch.outside)
        try write("mine", to: scratch.root + "/mine.txt")
        let fs = makeFileSystem(scratch)
        let data = Data("pwned".utf8).base64EncodedString()

        #expect(fs.perform("readFile", arguments: ["path": "out-link"]).failure?.code == "EACCES")
        #expect(fs.perform("stat", arguments: ["path": "out-link"]).failure?.code == "EACCES")
        #expect(fs.perform("writeFile", arguments: ["path": "out-link", "base64": data]).failure?.code == "EACCES")
        #expect(fs.perform("copyFile", arguments: ["from": "out-link", "to": "copy.txt"]).failure?.code == "EACCES")
        #expect(fs.perform("copyFile", arguments: ["from": "mine.txt", "to": "out-link"]).failure?.code == "EACCES")
        #expect(fs.perform("rename", arguments: ["from": "mine.txt", "to": "out-dir/mine.txt"]).failure?.code == "EACCES")
        #expect(fs.perform("rm", arguments: ["path": "out-dir/secret.txt"]).failure?.code == "EACCES")
        #expect(contents(secret) == "secret")
        #expect(contents(scratch.root + "/mine.txt") == "mine")
    }
}

private extension Result where Success == Any, Failure == BrowserReplFileSystemError {
    var failure: BrowserReplFileSystemError? {
        if case .failure(let error) = self { return error }
        return nil
    }

    /// The `type` of a `stat`/`lstat` result.
    var type: String? {
        guard case .success(let value) = self else { return nil }
        return (value as? [String: Any])?["type"] as? String
    }
}
