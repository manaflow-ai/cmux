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

    @Test("rename refuses to move or replace the working directory and the temporary root")
    func renameRefusesRoots() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try fileManager.createDirectory(atPath: scratch.base + "/tmp", withIntermediateDirectories: true)
        let fs = makeFileSystem(scratch)
        try write("mine", to: scratch.root + "/mine.txt")
        try fileManager.createDirectory(atPath: scratch.root + "/sub", withIntermediateDirectories: true)
        #expect(fs.perform("rename", arguments: ["from": scratch.root, "to": scratch.base + "/tmp/moved"]).failure?.code == "EACCES")
        #expect(fs.perform("rename", arguments: ["from": scratch.base + "/tmp", "to": scratch.root + "/sub/tmp"]).failure?.code == "EACCES")
        #expect(fs.perform("rename", arguments: ["from": "sub", "to": scratch.base + "/tmp"]).failure?.code == "EACCES")
        #expect(fileManager.fileExists(atPath: scratch.root + "/mine.txt"))
        #expect(fileManager.fileExists(atPath: scratch.base + "/tmp"))
    }

    /// Agent code cannot create a link, but it can move one that is already
    /// in the root, and two sessions on the same root run their fs calls on
    /// two threads. One session swapping such a link in for a directory must
    /// never let the other's write, checked against the directory, land
    /// through the link.
    @Test("A link swapped in by another session between the check and the write is never written through")
    func concurrentLinkSwapNeverEscapes() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try fileManager.createDirectory(atPath: scratch.root + "/sub", withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: scratch.root + "/escape", withDestinationPath: scratch.outside)
        let swapper = makeFileSystem(scratch)
        let writer = makeFileSystem(scratch)
        let escaped = scratch.outside + "/written.txt"
        let done = BrowserReplRaceFlag()

        let swapping = Task.detached {
            while !done.isSet {
                _ = swapper.perform("rename", arguments: ["from": "sub", "to": "held"])
                _ = swapper.perform("rename", arguments: ["from": "escape", "to": "sub"])
                _ = swapper.perform("rename", arguments: ["from": "sub", "to": "escape"])
                _ = swapper.perform("rename", arguments: ["from": "held", "to": "sub"])
            }
        }
        let writing = Task.detached {
            let payload = Data("x".utf8).base64EncodedString()
            for _ in 0..<5_000 where !FileManager.default.fileExists(atPath: escaped) {
                _ = writer.perform("writeFile", arguments: ["path": "sub/written.txt", "base64": payload])
            }
            done.set()
        }
        await writing.value
        await swapping.value

        #expect(!fileManager.fileExists(atPath: escaped))
    }
}

/// Another local process can change the tree between the REPL's path check
/// and its system call; the checks and the calls must be the same.
@Suite("Browser REPL fs against other processes")
struct BrowserReplFileSystemRaceTests {
    private typealias Scratch = BrowserReplFileSandboxTests.Scratch

    @Test("A directory another process swaps with a link to outside the root is never written or read through")
    func externalLinkSwapNeverEscapes() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let fileManager = FileManager.default
        try fileManager.createDirectory(atPath: scratch.root + "/sub", withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: URL(fileURLWithPath: scratch.root + "/sub/secret.txt"))
        try fileManager.createSymbolicLink(atPath: scratch.root + "/alt", withDestinationPath: scratch.outside)
        let fs = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: scratch.root), temporaryDirectory: scratch.base + "/tmp")
        let escaped = scratch.outside + "/written.txt"
        let root = scratch.root
        let done = BrowserReplRaceFlag()

        // Not through the REPL's fs: renamex_np swaps the directory and the
        // link in one step, as any other process of the user can.
        let swapping = Task.detached {
            while !done.isSet { _ = renamex_np(root + "/sub", root + "/alt", UInt32(RENAME_SWAP)) }
        }
        let probing = Task.detached { () -> String? in
            defer { done.set() }
            let payload = Data("x".utf8).base64EncodedString()
            for _ in 0..<5_000 {
                _ = fs.perform("writeFile", arguments: ["path": "sub/written.txt", "base64": payload])
                if FileManager.default.fileExists(atPath: escaped) { return "wrote \(escaped)" }
                if case .success(let value) = fs.perform("readFile", arguments: ["path": "sub/secret.txt"]),
                   let data = Data(base64Encoded: value as? String ?? ""),
                   String(decoding: data, as: UTF8.self) == "secret" {
                    return "read \(scratch.outside)/secret.txt"
                }
            }
            return nil
        }
        let escape = await probing.value
        await swapping.value

        #expect(escape == nil, "\(escape ?? "")")
        #expect(!fileManager.fileExists(atPath: escaped))
    }
}

/// A file that is not a regular file (a FIFO, a device) or one too large
/// to hold in memory must not hold a session's fs, or every session's.
@Suite("Browser REPL fs on special and large files")
struct BrowserReplFileSystemSpecialFileTests {
    private typealias Scratch = BrowserReplFileSandboxTests.Scratch

    /// Runs `operation` off the test's thread and returns its error code
    /// (`"ok"` on success); nil when it is still running after 10 s.
    /// Opening the FIFO for reading and writing then lets a blocked open or
    /// read finish, so a red run does not leave fs stuck.
    private func performBounded(
        _ fs: BrowserReplFileSystem,
        _ operation: String,
        _ arguments: [String: String],
        fifo: String
    ) async -> String? {
        let task = Task.detached { fs.perform(operation, arguments: arguments).failureCode }
        let result = await browserReplWithDeadline(seconds: 10) { await task.value }
        guard result == nil else { return result }
        // A blocked writer then gets EPIPE, not a signal that ends the tests.
        signal(SIGPIPE, SIG_IGN)
        var finished: String?
        while finished == nil {
            let unblock = open(fifo, O_RDWR | O_NONBLOCK)
            if unblock >= 0 { _ = write(unblock, "x", 1) }
            finished = await browserReplWithDeadline(seconds: 1) { await task.value }
            if unblock >= 0 { close(unblock) }
            if finished == nil { finished = await browserReplWithDeadline(seconds: 1) { await task.value } }
        }
        return nil
    }

    @Test("readFile, writeFile and copyFile refuse a FIFO at once instead of waiting for its other end")
    func fifoIsRefusedAtOnce() async throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let fifo = scratch.root + "/pipe"
        #expect(mkfifo(fifo, 0o600) == 0)
        let fs = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: scratch.root), temporaryDirectory: scratch.base + "/tmp")

        let read = await performBounded(fs, "readFile", ["path": "pipe"], fifo: fifo)
        let written = await performBounded(fs, "writeFile", ["path": "pipe", "base64": "eA=="], fifo: fifo)
        let copied = await performBounded(fs, "copyFile", ["from": "pipe", "to": "copy"], fifo: fifo)

        for (name, result) in [("readFile", read), ("writeFile", written), ("copyFile", copied)] {
            let failure = try #require(result, "\(name) waited for the FIFO's other end")
            #expect(failure == "EINVAL", "\(name): \(failure)")
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.root + "/copy"))
    }

    @Test("readFile refuses a file larger than its limit before reading it")
    func largeFileIsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // A sparse file: its size, not its blocks, is past the limit.
        let path = scratch.root + "/large.bin"
        let descriptor = open(path, O_WRONLY | O_CREAT, 0o600)
        #expect(descriptor >= 0)
        #expect(ftruncate(descriptor, off_t((64 << 20) + 1)) == 0)
        close(descriptor)
        let fs = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: scratch.root), temporaryDirectory: scratch.base + "/tmp")

        let result = fs.perform("readFile", arguments: ["path": "large.bin"])

        guard case .failure(let error) = result else {
            Issue.record("a 64 MiB + 1 byte file was read whole")
            return
        }
        #expect(error.code == "ERR_FS_FILE_TOO_LARGE")
        #expect(error.message.contains("64 MiB"), "\(error.message)")
    }
}

private extension Result where Success == Any, Failure == BrowserReplFileSystemError {
    /// The error code, or `"ok"`.
    var failureCode: String {
        if case .failure(let error) = self { return error.code }
        return "ok"
    }
}

/// A flag one task sets and another polls.
private final class BrowserReplRaceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
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
