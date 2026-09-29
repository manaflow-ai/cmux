import Foundation
import Testing

@testable import CmuxBrowser

@Suite("Browser REPL fs sandbox")
struct BrowserReplFileSandboxTests {
    /// A scratch directory with `work/` as the REPL root and `outside/` beside it.
    struct Scratch {
        let base: String
        var root: String { base + "/work" }
        var outside: String { base + "/outside" }

        init() throws {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-repl-fs-\(UUID().uuidString)")
            base = BrowserReplFileSandbox.canonicalize(url.path)
            try FileManager.default.createDirectory(atPath: base + "/work", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: base + "/outside", withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: URL(fileURLWithPath: base + "/outside/secret.txt"))
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: base)
        }
    }

    @Test("Relative paths resolve inside the root, including ones not created yet")
    func relativePaths() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let sandbox = BrowserReplFileSandbox(root: scratch.root)

        #expect(try sandbox.resolve("./artifacts/page.pdf", for: .write) == scratch.root + "/artifacts/page.pdf")
        #expect(try sandbox.resolve("a/../b.txt", for: .read) == scratch.root + "/b.txt")
        #expect(try sandbox.resolve(".", for: .read) == scratch.root)
        #expect(try sandbox.resolve(scratch.root + "/x.txt", for: .write) == scratch.root + "/x.txt")
    }

    @Test("Paths that leave the root are refused", arguments: ["../outside/secret.txt", "/etc/passwd", "a/../../outside", "~/../../etc/hosts/.."])
    func escapesAreRefused(path: String) throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let sandbox = BrowserReplFileSandbox(root: scratch.root)

        let resolved = try? sandbox.resolve(path, for: .read)
        if let resolved {
            #expect(resolved.hasPrefix(scratch.root + "/"))
        } else {
            #expect(throws: BrowserReplFileSystemError.self) { try sandbox.resolve(path, for: .read) }
        }
        #expect(throws: BrowserReplFileSystemError.self) { try sandbox.resolve("../outside/secret.txt", for: .write) }
    }

    @Test("A symbolic link inside the root cannot reach outside it")
    func symlinkEscapeIsRefused() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try FileManager.default.createSymbolicLink(atPath: scratch.root + "/link", withDestinationPath: scratch.outside)
        try FileManager.default.createSymbolicLink(
            atPath: scratch.root + "/dangling",
            withDestinationPath: scratch.outside + "/created-by-write.txt"
        )
        let sandbox = BrowserReplFileSandbox(root: scratch.root)

        #expect(throws: BrowserReplFileSystemError.self) { try sandbox.resolve("link/secret.txt", for: .read) }
        #expect(throws: BrowserReplFileSystemError.self) { try sandbox.resolve("link/new.txt", for: .write) }
        #expect(throws: BrowserReplFileSystemError.self) { try sandbox.resolve("dangling", for: .write) }
    }

    @Test("A reported download is readable but not writable")
    func downloadedFileIsReadOnly() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        var sandbox = BrowserReplFileSandbox(root: scratch.root)
        let download = scratch.outside + "/secret.txt"

        #expect(throws: BrowserReplFileSystemError.self) { try sandbox.resolve(download, for: .read) }
        sandbox.allowReading(download)
        #expect(try sandbox.resolve(download, for: .read) == download)
        #expect(throws: BrowserReplFileSystemError.self) { try sandbox.resolve(download, for: .write) }
        #expect(throws: BrowserReplFileSystemError.self) { try sandbox.resolve(scratch.outside + "/other.txt", for: .read) }
    }

    @Test("fs operations round-trip files and report Node error codes")
    func fileOperations() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let fs = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: scratch.root))
        let hello = Data("hello".utf8).base64EncodedString()

        #expect(throws: Never.self) { try fs.perform("mkdir", arguments: ["path": "artifacts/nested", "recursive": true]).get() }
        #expect(throws: Never.self) { try fs.perform("writeFile", arguments: ["path": "artifacts/a.txt", "base64": hello]).get() }
        #expect(throws: Never.self) {
            try fs.perform("writeFile", arguments: ["path": "artifacts/a.txt", "base64": hello, "append": true]).get()
        }
        let read = try fs.perform("readFile", arguments: ["path": "artifacts/a.txt"]).get() as? String
        #expect(read.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) } == "hellohello")

        let stat = try fs.perform("stat", arguments: ["path": "artifacts/a.txt"]).get() as? [String: Any]
        #expect(stat?["size"] as? Int64 == 10)
        #expect(stat?["type"] as? String == "file")

        let entries = try fs.perform("readdir", arguments: ["path": "artifacts"]).get() as? [[String: Any]]
        #expect(entries?.compactMap { $0["name"] as? String } == ["a.txt", "nested"])

        #expect(fs.perform("readFile", arguments: ["path": "missing.txt"]).failureCode == "ENOENT")
        #expect(fs.perform("mkdir", arguments: ["path": "artifacts"]).failureCode == "EEXIST")
        #expect(fs.perform("rm", arguments: ["path": "artifacts"]).failureCode == "ENOTEMPTY")
        #expect(fs.perform("readFile", arguments: ["path": "../outside/secret.txt"]).failureCode == "EACCES")
        #expect(fs.perform("writeFile", arguments: ["path": "no-such-dir/x.txt", "base64": hello]).failureCode == "ENOENT")
        #expect(fs.perform("rm", arguments: ["path": "."]).failureCode == "EACCES")

        #expect(throws: Never.self) { try fs.perform("rm", arguments: ["path": "artifacts", "recursive": true]).get() }
        #expect(fs.perform("exists", arguments: ["path": "artifacts"]).successValue as? Bool == false)
    }
}

extension BrowserReplFileSandboxTests {
    @Test("The ChatGPT scope also reaches the temporary directory; the Aside scope does not")
    func chatgptScopeAddsTemporaryDirectory() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        // `outside/` plays the user's temporary directory.
        let fs = BrowserReplFileSystem(
            sandbox: BrowserReplFileSandbox(root: scratch.root),
            temporaryDirectory: scratch.outside
        )
        let secret = scratch.outside + "/secret.txt"

        #expect(fs.perform("readFile", arguments: ["path": secret]).failureCode == "EACCES")
        let read = try fs.perform("readFile", arguments: ["path": secret, "scope": "chatgpt"]).get() as? String
        #expect(read == Data("secret".utf8).base64EncodedString())
        #expect(throws: Never.self) {
            try fs.perform("writeFile", arguments: ["path": scratch.outside + "/new.txt", "base64": "", "scope": "chatgpt"]).get()
        }
        #expect(fs.perform("rm", arguments: ["path": scratch.outside, "recursive": true, "scope": "chatgpt"]).failureCode == "EACCES")
        #expect(fs.perform("readFile", arguments: ["path": scratch.base + "/elsewhere.txt", "scope": "chatgpt"]).failureCode == "EACCES")
    }
}

private extension Result where Success == Any, Failure == BrowserReplFileSystemError {
    var failureCode: String? {
        if case .failure(let error) = self { return error.code }
        return nil
    }

    var successValue: Any? {
        if case .success(let value) = self { return value }
        return nil
    }
}
