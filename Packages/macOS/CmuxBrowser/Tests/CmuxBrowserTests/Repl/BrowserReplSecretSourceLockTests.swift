import Foundation
import Testing

@testable import CmuxBrowser

/// r16 native#4: `secrets.load` protects the file it read
/// (``BrowserReplSecretSources``) and a file navigation checks that set
/// while it holds ``BrowserReplFileSandbox/pathChangeLock`` and starts the
/// load. The protection must take the same lock, so it lands either before
/// a navigation's check (which then refuses the file) or after that
/// navigation started, never in between, where a check would pass on a
/// file the load is about to return.
@Suite("Browser REPL secret source protection lock")
struct BrowserReplSecretSourceLockTests {
    @Test("Protecting a secrets.load file waits for a file navigation's check")
    func protectionWaitsForTheNavigationLock() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("brepl-secret-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".env")
        try Data("TOKEN=value-for-lock-test\n".utf8).write(to: file)
        let identity = try #require(BrowserReplFileIdentity(path: file.path))

        let protected = DispatchSemaphore(value: 0)
        let protectedWhileHeld: Bool = BrowserReplFileSandbox.pathChangeLock.withLock {
            Thread.detachNewThread {
                BrowserReplSecretSources.shared.protect(identity)
                protected.signal()
            }
            // With the lock held the protection cannot land; without it, it
            // lands at once. The wait only bounds the test's time: a
            // protection that waits for the lock can never signal here.
            return protected.wait(timeout: .now() + 1) == .success
        }
        #expect(!protectedWhileHeld, "the protection changed the set while a navigation check held the lock")
        if !protectedWhileHeld { protected.wait() }
        #expect(BrowserReplSecretSources.shared.contains(path: file.path))
    }
}
