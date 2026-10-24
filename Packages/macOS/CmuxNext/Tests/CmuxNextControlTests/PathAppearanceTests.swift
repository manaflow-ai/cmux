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
