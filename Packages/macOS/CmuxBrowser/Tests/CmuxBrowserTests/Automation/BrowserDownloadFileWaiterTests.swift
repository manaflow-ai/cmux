import Foundation
import Testing
@testable import CmuxBrowser

@Suite("BrowserDownloadFileWaiter")
struct BrowserDownloadFileWaiterTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-download-wait-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func readyImmediatelyWhenFileAlreadyHasBytes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("done.bin")
        try Data([0x1, 0x2, 0x3]).write(to: file)

        let outcome = BrowserDownloadFileWaiter().wait(forDownloadAt: file.path, timeout: 1.0)
        #expect(outcome == .ready)
    }

    @Test func pathIsReadyTreatsZeroLengthAsNotReady() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("empty.bin")
        try Data().write(to: file)

        let waiter = BrowserDownloadFileWaiter()
        #expect(waiter.pathIsReady(file.path) == false)
    }

    @Test func timesOutWhenFileNeverAppears() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("never.bin")

        let outcome = BrowserDownloadFileWaiter().wait(forDownloadAt: missing.path, timeout: 0.2)
        #expect(outcome == .timeout)
    }

    @Test func watcherSetupFailsWhenEnclosingDirectoryMissing() {
        let bogusDir = "/cmux-nonexistent-\(UUID().uuidString)/file.bin"
        let outcome = BrowserDownloadFileWaiter().wait(forDownloadAt: bogusDir, timeout: 0.2)
        guard case .watcherSetupFailed = outcome else {
            Issue.record("expected watcherSetupFailed, got \(outcome)")
            return
        }
    }

    @Test func readyAfterFileBecomesNonEmptyDuringWait() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("late.bin")

        let writer = Task.detached {
            try? await Task.sleep(nanoseconds: 50_000_000)
            try? Data([0xAA]).write(to: file)
        }
        defer { writer.cancel() }

        let outcome = BrowserDownloadFileWaiter().wait(forDownloadAt: file.path, timeout: 2.0)
        #expect(outcome == .ready)
    }
}
