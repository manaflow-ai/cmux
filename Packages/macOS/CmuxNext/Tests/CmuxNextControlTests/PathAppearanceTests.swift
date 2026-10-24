import CmuxNextWakeups
import Foundation
import Testing

/// A client whose daemon is not up waits for the daemon's socket to appear, on a file-system event,
/// instead of sleeping and retrying (the Feed's reports reader slept 5 s per failed attempt).
@Suite(.timeLimit(.minutes(1))) struct PathAppearanceTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("path-appearance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aWaitReturnsOnceThePathIsMadeEvenInAFolderThatDidNotExist() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("home/acpmux.sock").path
        let waiter = Task { await PathAppearance().wait(for: socket) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))
        await waiter.value
        #expect(FileManager.default.fileExists(atPath: socket))
    }

    /// The wait follows the path down: armed on the parent while the socket's folder is missing, it
    /// re-arms on that folder once it appears, and the socket made there ends the wait. (The race the
    /// first version lost on the fleet: the folder made between choosing the parent and arming its
    /// watch, so the socket's event went to a folder nobody watched; the armed-late check now sees
    /// the deeper folder and re-resolves.)
    @Test func aFolderMadeBeforeTheWatchIsArmedIsNotMissed() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let socket = home.appendingPathComponent("acpmux.sock").path
        let waiter = Task { await PathAppearance().wait(for: socket) }
        // Give the wait time to arm on `root`, then make the folder and, a moment later, the socket:
        // the socket's event goes to `home`.
        // wakeup-allow: test choreography, the wait arms on root first
        try await Task.sleep(for: .milliseconds(100))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // wakeup-allow: test choreography, the wait re-arms on home
        try await Task.sleep(for: .milliseconds(100))
        #expect(FileManager.default.createFile(atPath: socket, contents: Data()))
        await waiter.value
    }

    @Test func aWaitForAnExistingPathReturnsAtOnce() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        await PathAppearance().wait(for: root.path)
    }

    @Test func aCancelledWaitReturnsWithoutThePath() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let waiter = Task { await PathAppearance().wait(for: root.appendingPathComponent("never.sock").path) }
        waiter.cancel()
        await waiter.value
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("never.sock").path))
    }
}
