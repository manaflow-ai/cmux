import Foundation
import Testing

@testable import CmuxBrowser

/// `secrets.load` protects the file it read (``BrowserReplSecretSources``)
/// and a file navigation checks that set while it holds
/// ``BrowserReplFileSandbox/pathChangeLock`` and starts the load. The open
/// and the protection must be one hold of the same lock (r16 native#4 put
/// the protection under it; r18 native#1 the open as well), so a
/// navigation runs wholly before the open or after the protection, never
/// in between, where a check would pass on a file the load is about to
/// return.
@Suite("Browser REPL secret source protection lock")
struct BrowserReplSecretSourceLockTests {
    /// r18 native#1 / entry#2: the open `secrets.load` reads and the
    /// protection of what it opened are one hold of the lock a file
    /// navigation checks under. The `opened` hook runs in that window and
    /// starts a navigation to the file there: it must wait for the lock and
    /// then be refused, not pass its check on a file just opened as a
    /// secrets source.
    @Test("A file navigation cannot pass its check between secrets.load's open and its protection")
    func navigationCannotRunBetweenOpenAndProtection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brepl-secret-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootPath = BrowserReplFileSandbox.canonicalize(directory.path)
        try Data(#"{"example.com":{"pw":"open-window-secret"}}"#.utf8).write(to: URL(fileURLWithPath: rootPath + "/secrets.json"))
        let url = URL(fileURLWithPath: rootPath + "/secrets.json").absoluteString
        let root = BrowserReplFileRoot(path: rootPath)
        let fs = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: rootPath))

        let loaded = NavigationOutcome()
        let finished = DispatchSemaphore(value: 0)
        let finishedInWindow = NavigationOutcome()
        let opened: (BrowserReplFileIdentity) throws -> Void = { identity in
            Thread.detachNewThread {
                let started = (try? BrowserReplFileSandbox.withPinnedFileAccess(url, roots: [root]) { _ in true }) ?? false
                loaded.set(started)
                finished.signal()
            }
            // The wait only bounds the test's time: a navigation that waits
            // for the lock cannot finish while the hook runs under it.
            finishedInWindow.set(finished.wait(timeout: .now() + 1) == .success)
            try BrowserReplSecretSources.shared.protect(identity)
        }
        let result = fs.perform("readFile", arguments: ["path": "secrets.json"], copyContents: nil, opened: opened)
        guard case .success = result else {
            Issue.record("readFile failed: \(result)")
            return
        }
        if finishedInWindow.value != true { finished.wait() }
        #expect(loaded.value == false, "a file navigation started loading the secrets file between its open and its protection")
        #expect(finishedInWindow.value == false, "the navigation's check ran while secrets.load had the file open and unprotected")
    }
}

/// r18 native#3: the files `secrets.load` protects are process-wide, so
/// the set is bounded. A file whose identity no longer exists (removed
/// under every name) is reclaimed; a live protection is never dropped, so
/// a new one past the bound is refused, and `secrets.load` fails with
/// nothing read.
@Suite("Browser REPL secret source bound")
struct BrowserReplSecretSourceBoundTests {
    private static func scratch() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brepl-secret-bound-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return BrowserReplFileSandbox.canonicalize(directory.path)
    }

    private static func file(_ directory: String, _ name: String) throws -> (path: String, identity: BrowserReplFileIdentity) {
        let path = directory + "/" + name
        try Data(#"{"example.com":{"pw":"bound-test-secret"}}"#.utf8).write(to: URL(fileURLWithPath: path))
        return (path, try #require(BrowserReplFileIdentity(path: path)))
    }

    @Test func pastTheBoundANewSourceIsRefusedUntilAProtectedFileIsGone() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let first = try Self.file(directory, "first.json")
        let second = try Self.file(directory, "second.json")
        let third = try Self.file(directory, "third.json")
        let sources = BrowserReplSecretSources(maximumSources: 2)
        try sources.protect(first.identity)
        try sources.protect(second.identity)
        // A file already protected takes no more room.
        try sources.protect(first.identity)
        #expect(throws: BrowserReplFileSystemError.self) { try sources.protect(third.identity) }
        #expect(!sources.contains(path: third.path), "a refused protection still grew the set")
        #expect(sources.contains(path: first.path) && sources.contains(path: second.path), "a live protection was dropped")
        // Removed under every name: no tab can load it, so its room is reclaimed.
        try FileManager.default.removeItem(atPath: first.path)
        try sources.protect(third.identity)
        #expect(sources.contains(path: third.path))
        #expect(sources.contains(path: second.path))
    }

    /// A refused protection fails the read that asked for it, with nothing read.
    @Test func aRefusedProtectionFailsTheRead() throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        _ = try Self.file(directory, "secrets.json")
        let fs = BrowserReplFileSystem(sandbox: BrowserReplFileSandbox(root: directory))
        let refusal = BrowserReplFileSystemError(code: "invalid", message: "refused")
        let result = fs.perform("readFile", arguments: ["path": "secrets.json"], copyContents: nil, opened: { _ in throw refusal })
        guard case .failure(let error) = result else {
            Issue.record("the read succeeded although its protection was refused")
            return
        }
        #expect(error.code == "invalid")
    }
}

/// A value one thread sets and another reads after a semaphore.
private final class NavigationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}
