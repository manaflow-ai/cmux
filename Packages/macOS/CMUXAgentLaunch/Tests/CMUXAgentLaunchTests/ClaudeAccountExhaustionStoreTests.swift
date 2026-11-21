import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct ClaudeAccountExhaustionStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-exhaustion-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("claude-account-exhaustion.json")
    }

    @Test func markThenReadUntilExpiry() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ClaudeAccountExhaustionStore(fileURL: url, clock: { Date(timeIntervalSince1970: 1_000_000) })
        let now = Date(timeIntervalSince1970: 1_000_000)
        try await store.markExhausted(accountKey: "/u/.claude", until: now.addingTimeInterval(60))
        #expect(await store.exhaustedUntil(now: now)["/u/.claude"] == now.addingTimeInterval(60))
        #expect(await store.exhaustedUntil(now: now.addingTimeInterval(61)).isEmpty)
    }

    @Test func persistsAcrossInstances() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        try await ClaudeAccountExhaustionStore(fileURL: url, clock: { Date(timeIntervalSince1970: 1_000_000) }).markExhausted(accountKey: "a", until: now.addingTimeInterval(60))
        #expect(await ClaudeAccountExhaustionStore(fileURL: url, clock: { Date(timeIntervalSince1970: 1_000_000) }).exhaustedUntil(now: now).keys.sorted() == ["a"])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func clearRemovesEntry() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ClaudeAccountExhaustionStore(fileURL: url, clock: { Date(timeIntervalSince1970: 1_000_000) })
        let now = Date(timeIntervalSince1970: 1_000_000)
        try await store.markExhausted(accountKey: "a", until: now.addingTimeInterval(60))
        try await store.markExhausted(accountKey: "b", until: now.addingTimeInterval(60))
        try await store.clear(accountKey: "a")
        #expect(await store.exhaustedUntil(now: now).keys.sorted() == ["b"])
    }

    /// Each write reads the file, changes one entry and replaces the file, so writes that
    /// overlapped would drop each other's entries.
    @Test func concurrentMarksAllPersist() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ClaudeAccountExhaustionStore(fileURL: url, clock: { Date(timeIntervalSince1970: 1_000_000) })
        let now = Date(timeIntervalSince1970: 1_000_000)
        let keys = (0..<32).map { "/u/.claude-\($0)" }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask { try await store.markExhausted(accountKey: key, until: now.addingTimeInterval(60)) }
            }
            try await group.waitForAll()
        }
        #expect(await store.exhaustedUntil(now: now).keys.sorted() == keys.sorted())
    }

    @Test func corruptStoreReadsEmpty() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{".write(to: url, atomically: true, encoding: .utf8)
        let store = ClaudeAccountExhaustionStore(fileURL: url, clock: { Date(timeIntervalSince1970: 1_000_000) })
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(await store.exhaustedUntil(now: now) == [:])
        #expect(store.snapshotExhaustedUntil(now: now) == [:])
        try await store.markExhausted(accountKey: "a", until: now.addingTimeInterval(60))
        #expect(await store.exhaustedUntil(now: now).keys.sorted() == ["a"])
    }

    /// The CLI's synchronous read sees what the app wrote, from another instance, and drops
    /// entries that already reset.
    @Test func snapshotReadsWithoutAwaitingTheStore() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let writer = ClaudeAccountExhaustionStore(fileURL: url, clock: { now })
        try await writer.markExhausted(accountKey: "a", until: now.addingTimeInterval(60))
        try await writer.markExhausted(accountKey: "b", until: now.addingTimeInterval(10))
        let reader = ClaudeAccountExhaustionStore(fileURL: url)
        #expect(reader.snapshotExhaustedUntil(now: now.addingTimeInterval(30)) == ["a": now.addingTimeInterval(60)])
    }

    @Test func defaultFileURLIsUnderCmuxterm() {
        #expect(ClaudeAccountExhaustionStore.defaultFileURL(homeDirectory: "/Users/u").path
            == "/Users/u/.cmuxterm/claude-account-exhaustion.json")
    }
}
