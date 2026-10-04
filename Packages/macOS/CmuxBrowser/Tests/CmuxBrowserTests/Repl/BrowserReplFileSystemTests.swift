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

    /// The fs holds each root open from when it first opens it: another
    /// process that renames the working directory or the temporary root
    /// away and puts a link to outside in its place redirects nothing.
    @Test("A root renamed away after the fs opened it, with a link to outside in its place, is still the root")
    func rootSwappedAfterSetupStaysTheRoot() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let fileManager = FileManager.default
        let temporary = scratch.base + "/tmp"
        try fileManager.createDirectory(atPath: temporary, withIntermediateDirectories: true)
        let fs = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: scratch.root), temporaryDirectory: temporary)
        let payload = Data("x".utf8).base64EncodedString()
        // The session has used both roots once.
        for path in ["first.txt", temporary + "/first.txt"] {
            if case .failure(let error) = fs.perform("writeFile", arguments: ["path": path, "base64": payload]) {
                Issue.record("\(path): \(error.message)")
            }
        }

        // Another process moves both roots away and links them to outside.
        let movedRoot = scratch.base + "/moved-work"
        let movedTemporary = scratch.base + "/moved-tmp"
        #expect(rename(scratch.root, movedRoot) == 0)
        #expect(rename(temporary, movedTemporary) == 0)
        try fileManager.createSymbolicLink(atPath: scratch.root, withDestinationPath: scratch.outside)
        try fileManager.createSymbolicLink(atPath: temporary, withDestinationPath: scratch.outside)

        for path in ["second.txt", temporary + "/third.txt"] {
            if case .failure(let error) = fs.perform("writeFile", arguments: ["path": path, "base64": payload]) {
                Issue.record("\(path): \(error.message)")
            }
        }
        let read = fs.perform("readFile", arguments: ["path": "secret.txt"])
        let listed = fs.perform("readdir", arguments: ["path": "."])

        for name in ["second.txt", "third.txt"] {
            #expect(!fileManager.fileExists(atPath: scratch.outside + "/" + name), "\(name) went through the link")
        }
        #expect(fileManager.fileExists(atPath: movedRoot + "/second.txt"))
        #expect(fileManager.fileExists(atPath: movedTemporary + "/third.txt"))
        if case .success = read { Issue.record("read outside/secret.txt through the swapped root") }
        let names = ((try? listed.get()) as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == ["first.txt", "second.txt"], "\(String(describing: names))")
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

    @Test("copyFile refuses a source larger than one call's write limit before creating the destination")
    func largeCopyIsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // A sparse file: its size, not its blocks, is past the limit.
        let path = scratch.root + "/large.bin"
        let descriptor = open(path, O_WRONLY | O_CREAT, 0o600)
        #expect(descriptor >= 0)
        #expect(ftruncate(descriptor, off_t((256 << 20) + 1)) == 0)
        close(descriptor)
        let fs = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: scratch.root), temporaryDirectory: scratch.base + "/tmp")

        let result = fs.perform("copyFile", arguments: ["from": "large.bin", "to": "copy.bin"])

        guard case .failure(let error) = result else {
            Issue.record("a 256 MiB + 1 byte file was copied whole")
            return
        }
        #expect(error.code == "EFBIG")
        #expect(error.message.contains("256 MiB"), "\(error.message)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root) == ["large.bin"])
    }

    private func makeFileSystem(
        _ scratch: Scratch,
        budget: BrowserReplWriteBudget,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> BrowserReplFileSystem {
        BrowserReplFileSystem(
            sandbox: BrowserReplFileSandbox(root: scratch.root),
            temporaryDirectory: scratch.base + "/tmp",
            rootDescriptor: nil,
            temporaryDescriptor: nil,
            writeBudget: budget,
            isCancelled: isCancelled
        )
    }

    @Test("writeFile past one call's limit is refused and keeps the existing file")
    func largeWriteIsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try Data("keep".utf8).write(to: URL(fileURLWithPath: scratch.root + "/file.txt"))
        let fs = makeFileSystem(scratch, budget: BrowserReplWriteBudget(perCall: 1000, perSession: 1 << 20))

        let result = fs.perform("writeFile", arguments: ["path": "file.txt", "base64": Data(count: 1001).base64EncodedString()])

        guard case .failure(let error) = result else {
            Issue.record("a write past the limit was made")
            return
        }
        #expect(error.code == "EFBIG")
        #expect(error.message.contains("1000 bytes"), "\(error.message)")
        #expect(FileManager.default.contents(atPath: scratch.root + "/file.txt") == Data("keep".utf8))
    }

    @Test("Writes, appends and copies share one session budget; past it they are refused with a way out")
    func sessionBudgetIsShared() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let budget = BrowserReplWriteBudget(perCall: 2000, perSession: 4000)
        let fs = makeFileSystem(scratch, budget: budget)
        // A session that changes its root keeps its budget.
        let moved = makeFileSystem(scratch, budget: budget)
        let chunk = Data(count: 1500).base64EncodedString()

        let first = fs.perform("writeFile", arguments: ["path": "a.bin", "base64": chunk])
        let appended = fs.perform("writeFile", arguments: ["path": "a.bin", "base64": chunk, "append": true])
        let tooMuch = moved.perform("copyFile", arguments: ["from": "a.bin", "to": "b.bin"])
        let small = moved.perform("writeFile", arguments: ["path": "c.bin", "base64": Data(count: 1000).base64EncodedString()])
        let past = moved.perform("writeFile", arguments: ["path": "d.bin", "base64": "eA=="])

        #expect(first.failureCode == "ok" && appended.failureCode == "ok" && small.failureCode == "ok")
        // 3,000 bytes is past one call's 2,000.
        #expect(tooMuch.failureCode == "EFBIG")
        guard case .failure(let error) = past else {
            Issue.record("a write past the session's budget was made")
            return
        }
        #expect(error.code == "EDQUOT")
        #expect(error.message.contains("cmux browser repl reset"), "\(error.message)")
        #expect(!FileManager.default.fileExists(atPath: scratch.root + "/d.bin"))
    }

    /// Empty files, directories, renames and removals write no bytes, but
    /// each changes the file system: a session makes at most 100,000 such
    /// changes, so a loop of them cannot exhaust the volume's entries.
    @Test("Entry changes (empty writes, mkdir, rename, rm) count against the session's budget")
    func entryChangesAreBudgeted() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let fs = makeFileSystem(scratch, budget: BrowserReplWriteBudget())
        #expect(fs.perform("writeFile", arguments: ["path": "a", "base64": ""]).failureCode == "ok")
        var renamed = 1
        var refused: String?
        // Renames add no entry, so the loop leaves the scratch tree small.
        while renamed <= 100_000 {
            let (from, to) = renamed % 2 == 1 ? ("a", "b") : ("b", "a")
            let code = fs.perform("rename", arguments: ["from": from, "to": to]).failureCode
            if code != "ok" {
                refused = code
                break
            }
            renamed += 1
        }
        #expect(refused == "EDQUOT", "\(renamed) changes were made without a limit")
        #expect(renamed <= 100_000)
        for (op, arguments) in [
            ("writeFile", ["path": "c", "base64": ""] as [String: Any]),
            ("mkdir", ["path": "d"]),
            ("rm", ["path": renamed % 2 == 1 ? "a" : "b"]),
        ] {
            #expect(fs.perform(op, arguments: arguments).failureCode == "EDQUOT", "\(op) was not counted")
        }
        #expect(!FileManager.default.fileExists(atPath: scratch.root + "/c"))
        #expect(!FileManager.default.fileExists(atPath: scratch.root + "/d"))
    }

    /// `readdir` and `rm -r` run on the session's thread; on a large tree a
    /// cell that timed out (or a session that closed) must not wait for the
    /// whole traversal.
    @Test("A cancelled readdir or recursive rm of a large directory stops")
    func cancelledTraversalStops() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let big = scratch.root + "/big"
        try FileManager.default.createDirectory(atPath: big + "/nested", withIntermediateDirectories: true)
        for index in 0..<3000 {
            #expect(FileManager.default.createFile(atPath: big + "/f\(index)", contents: nil))
        }
        let fs = makeFileSystem(scratch, budget: BrowserReplWriteBudget(), isCancelled: { true })

        #expect(fs.perform("readdir", arguments: ["path": "big"]).failureCode == "ECANCELED")
        #expect(fs.perform("rm", arguments: ["path": "big", "recursive": true]).failureCode == "ECANCELED")
        #expect(FileManager.default.fileExists(atPath: big))
        // Small ones still finish: the check is between chunks of entries.
        try FileManager.default.createDirectory(atPath: scratch.root + "/small/inner", withIntermediateDirectories: true)
        #expect(fs.perform("readdir", arguments: ["path": "small"]).failureCode == "ok")
    }

    /// A root that does not exist yet is opened (and made, by `mkdir -p`)
    /// only when an operation first needs it. Another session whose root is
    /// above it can move a link it holds into the place of the root's
    /// parent before then; the root must not be made or opened through it.
    @Test("A missing root whose parent became a link is neither made nor opened through it")
    func missingRootThroughSwappedParentIsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let fs = BrowserReplFileSystem(
            sandbox: BrowserReplFileSandbox(root: scratch.root + "/a/b"),
            temporaryDirectory: scratch.base + "/tmp"
        )
        // The link another session moved into place (fs.rename keeps a link a link).
        try FileManager.default.createSymbolicLink(atPath: scratch.root + "/a", withDestinationPath: scratch.outside)

        let made = fs.perform("mkdir", arguments: ["path": ".", "recursive": true])
        let wrote = fs.perform("writeFile", arguments: ["path": "x.txt", "base64": Data("x".utf8).base64EncodedString()])
        let read = fs.perform("readFile", arguments: ["path": "../secret.txt"])

        #expect(made.failureCode == "EACCES", "\(made)")
        #expect(wrote.failureCode != "ok")
        #expect(read.failureCode != "ok")
        #expect(!FileManager.default.fileExists(atPath: scratch.outside + "/b"))
    }

    @Test("A root that exists is held from a walk that follows no link, also when a parent is a link by then")
    func existingRootThroughSwappedParentIsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try FileManager.default.createDirectory(atPath: scratch.outside + "/b", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: scratch.root + "/a/b", withIntermediateDirectories: true)
        let sandbox = BrowserReplFileSandbox(root: scratch.root + "/a/b")
        // Swapped after the path was resolved, before the fs opens it.
        try FileManager.default.removeItem(atPath: scratch.root + "/a")
        try FileManager.default.createSymbolicLink(atPath: scratch.root + "/a", withDestinationPath: scratch.outside)
        let fs = BrowserReplFileSystem(sandbox: sandbox, temporaryDirectory: scratch.base + "/tmp")

        let wrote = fs.perform("writeFile", arguments: ["path": "x.txt", "base64": Data("x".utf8).base64EncodedString()])

        #expect(wrote.failureCode == "EACCES", "\(wrote)")
        #expect(!FileManager.default.fileExists(atPath: scratch.outside + "/b/x.txt"))
    }

    @Test("A cancelled copy or write stops between chunks and a copy leaves no file")
    func cancelledCopyStops() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let size = 3 * BrowserReplFileSystem.chunkBytes
        try Data(count: size).write(to: URL(fileURLWithPath: scratch.root + "/source.bin"))
        let fs = makeFileSystem(scratch, budget: BrowserReplWriteBudget(), isCancelled: { true })

        let copied = fs.perform("copyFile", arguments: ["from": "source.bin", "to": "copy.bin"])
        let written = fs.perform("writeFile", arguments: ["path": "written.bin", "base64": Data(count: size).base64EncodedString()])

        #expect(copied.failureCode == "ECANCELED")
        #expect(written.failureCode == "ECANCELED")
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.root).sorted() == ["source.bin", "written.bin"])
        let partial = try FileManager.default.attributesOfItem(atPath: scratch.root + "/written.bin")[.size] as? NSNumber
        #expect((partial?.intValue ?? size) < size)
    }

    @Test("copyFile copies the bytes, the mode and replaces the destination")
    func copyKeepsBytesAndMode() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let bytes = Data((0..<(2 * BrowserReplFileSystem.chunkBytes + 7)).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: URL(fileURLWithPath: scratch.root + "/source.bin"))
        #expect(chmod(scratch.root + "/source.bin", 0o640) == 0)
        try Data("old".utf8).write(to: URL(fileURLWithPath: scratch.root + "/copy.bin"))
        let fs = makeFileSystem(scratch, budget: BrowserReplWriteBudget())

        #expect(fs.perform("copyFile", arguments: ["from": "source.bin", "to": "copy.bin"]).failureCode == "ok")

        #expect(FileManager.default.contents(atPath: scratch.root + "/copy.bin") == bytes)
        let mode = try FileManager.default.attributesOfItem(atPath: scratch.root + "/copy.bin")[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o640)
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
