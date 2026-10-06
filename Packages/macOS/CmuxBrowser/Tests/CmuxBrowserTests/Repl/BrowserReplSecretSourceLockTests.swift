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
        let opened: (BrowserReplFileIdentity) -> Void = { identity in
            Thread.detachNewThread {
                let started = (try? BrowserReplFileSandbox.withPinnedFileAccess(url, roots: [root]) { _ in true }) ?? false
                loaded.set(started)
                finished.signal()
            }
            // The wait only bounds the test's time: a navigation that waits
            // for the lock cannot finish while the hook runs under it.
            finishedInWindow.set(finished.wait(timeout: .now() + 1) == .success)
            BrowserReplSecretSources.shared.protect(identity)
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

/// A value one thread sets and another reads after a semaphore.
private final class NavigationOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    var value: Bool? { lock.withLock { stored } }
    func set(_ value: Bool) { lock.withLock { stored = value } }
}
