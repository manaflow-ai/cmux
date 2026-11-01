import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite struct ClaudeAccountExhaustionStoreTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-exhaustion-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("claude-account-exhaustion.json")
    }

    @Test func markThenReadUntilExpiry() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ClaudeAccountExhaustionStore(fileURL: url, clock: { Date(timeIntervalSince1970: 1_000_000) })
        let now = Date(timeIntervalSince1970: 1_000_000)
        try store.markExhausted(accountKey: "/u/.claude", until: now.addingTimeInterval(60))
        #expect(store.exhaustedUntil(now: now)["/u/.claude"] == now.addingTimeInterval(60))
        #expect(store.exhaustedUntil(now: now.addingTimeInterval(61)).isEmpty)
    }

    @Test func persistsAcrossInstances() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        try ClaudeAccountExhaustionStore(fileURL: url, clock: { Date(timeIntervalSince1970: 1_000_000) }).markExhausted(accountKey: "a", until: now.addingTimeInterval(60))
        #expect(ClaudeAccountExhaustionStore(fileURL: url, clock: { Date(timeIntervalSince1970: 1_000_000) }).exhaustedUntil(now: now).keys.sorted() == ["a"])
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func clearRemovesEntry() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ClaudeAccountExhaustionStore(fileURL: url, clock: { Date(timeIntervalSince1970: 1_000_000) })
        let now = Date(timeIntervalSince1970: 1_000_000)
        try store.markExhausted(accountKey: "a", until: now.addingTimeInterval(60))
        try store.markExhausted(accountKey: "b", until: now.addingTimeInterval(60))
        try store.clear(accountKey: "a")
        #expect(store.exhaustedUntil(now: now).keys.sorted() == ["b"])
    }

    @Test func corruptStoreReadsEmpty() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{".write(to: url, atomically: true, encoding: .utf8)
        let store = ClaudeAccountExhaustionStore(fileURL: url, clock: { Date(timeIntervalSince1970: 1_000_000) })
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(store.exhaustedUntil(now: now) == [:])
        try store.markExhausted(accountKey: "a", until: now.addingTimeInterval(60))
        #expect(store.exhaustedUntil(now: now).keys.sorted() == ["a"])
    }

    @Test func defaultFileURLIsUnderCmuxterm() {
        #expect(ClaudeAccountExhaustionStore.defaultFileURL(homeDirectory: "/Users/u").path
            == "/Users/u/.cmuxterm/claude-account-exhaustion.json")
    }
}
