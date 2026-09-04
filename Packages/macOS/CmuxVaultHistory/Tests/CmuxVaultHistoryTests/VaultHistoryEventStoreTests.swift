import Foundation
import Testing

@testable import CmuxVaultHistory

@Suite struct VaultHistoryEventStoreTests {
    private func makeTempFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "vault-history-tests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "history.jsonl", directoryHint: .notDirectory)
    }

    private func event(
        id: String,
        secondsAgo: TimeInterval,
        kind: VaultHistoryEventKind = .workspaceCreated,
        title: String = "ws",
        reference: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> VaultHistoryEvent {
        VaultHistoryEvent(
            id: id,
            timestamp: reference.addingTimeInterval(-secondsAgo),
            kind: kind,
            title: title,
            subject: VaultHistorySubject(workspaceId: UUID())
        )
    }

    @Test func appendedEventsRoundTripThroughDisk() async throws {
        let fileURL = try makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = VaultHistoryEventStore(fileURL: fileURL)
        let created = VaultHistoryEvent(
            id: "e1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .workspaceRenamed,
            title: "renamed",
            previousTitle: "original",
            subject: VaultHistorySubject(workspaceId: UUID(), directory: "/tmp/project")
        )
        let closed = VaultHistoryEvent(
            id: "e2",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            kind: .windowClosed,
            title: "win",
            workspaceCount: 3,
            subject: VaultHistorySubject(windowId: UUID())
        )
        #expect(await store.append(created))
        #expect(await store.append(closed))

        let reloaded = VaultHistoryEventStore(fileURL: fileURL)
        let events = await reloaded.recentEvents()
        #expect(events.count == 2)
        #expect(events.first?.id == "e2")
        #expect(events.first?.workspaceCount == 3)
        #expect(events.last?.id == "e1")
        #expect(events.last?.previousTitle == "original")
        #expect(events.last?.subject.directory == "/tmp/project")
        #expect(events.last?.kind == .workspaceRenamed)
    }

    @Test func recentEventsReturnsNewestFirstWithStableTieBreakAndLimit() async {
        let store = VaultHistoryEventStore(fileURL: nil)
        #expect(await store.append(event(id: "old", secondsAgo: 300)))
        #expect(await store.append(event(id: "tie-a", secondsAgo: 10)))
        #expect(await store.append(event(id: "tie-z", secondsAgo: 10)))
        #expect(await store.append(event(id: "mid", secondsAgo: 100)))

        let all = await store.recentEvents()
        #expect(all.map(\.id) == ["tie-z", "tie-a", "mid", "old"])
        #expect(await store.recentEvents(limit: 2).map(\.id) == ["tie-z", "tie-a"])
    }

    @Test func failedPersistenceDoesNotEnterTheReadableSnapshot() async {
        let unwritableURL = URL(fileURLWithPath: "/dev/null/vault-history.jsonl")
        let store = VaultHistoryEventStore(fileURL: unwritableURL)

        #expect(await store.append(event(id: "rejected", secondsAgo: 0)) == false)
        #expect(await store.recentEvents().isEmpty)
    }

    @Test func retentionCompactsFileAndKeepsNewestEvents() async throws {
        let fileURL = try makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let retention = VaultHistoryRetentionPolicy(
            maxStoredEvents: 5,
            maxFileBytes: 1_024,
            maxLoadBytes: 64 * 1_024
        )
        let store = VaultHistoryEventStore(fileURL: fileURL, retention: retention)
        for index in 0..<50 {
            #expect(await store.append(event(
                id: "e\(index)",
                secondsAgo: TimeInterval(1_000 - index)
            )))
        }

        let events = await store.recentEvents()
        #expect(!events.isEmpty)
        #expect(events.count <= retention.maxStoredEvents)
        #expect(events.first?.id == "e49")
        let expectedIDs = (0..<events.count).map { "e\(49 - $0)" }
        #expect(events.map(\.id) == expectedIDs)

        let fileSize = try #require(
            try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int
        )
        #expect(fileSize <= retention.maxFileBytes)

        let reloaded = VaultHistoryEventStore(fileURL: fileURL, retention: retention)
        #expect(await reloaded.recentEvents().map(\.id) == expectedIDs)
    }

    @Test func oversizedEventIsRejectedWithoutDisplacingReadableHistory() async throws {
        let fileURL = try makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let retention = VaultHistoryRetentionPolicy(
            maxStoredEvents: 5,
            maxFileBytes: 1_024,
            maxLoadBytes: 4_096
        )
        let store = VaultHistoryEventStore(fileURL: fileURL, retention: retention)
        #expect(await store.append(event(id: "accepted", secondsAgo: 1)))
        #expect(await store.append(event(
            id: "oversized",
            secondsAgo: 0,
            title: String(repeating: "x", count: 2_048)
        )) == false)

        #expect(await store.recentEvents().map(\.id) == ["accepted"])
        let fileSize = try #require(
            try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int
        )
        #expect(fileSize <= retention.maxFileBytes)
    }

    @Test func loadIsBoundedAndSkipsPartialLeadingLine() async throws {
        let fileURL = try makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let writer = VaultHistoryEventStore(fileURL: fileURL)
        for index in 0..<200 {
            #expect(await writer.append(event(
                id: "e\(index)",
                secondsAgo: TimeInterval(10_000 - index)
            )))
        }

        let reader = VaultHistoryEventStore(
            fileURL: fileURL,
            retention: VaultHistoryRetentionPolicy(
                maxStoredEvents: 1_000,
                maxFileBytes: 64 * 1_024 * 1_024,
                maxLoadBytes: 4_096
            )
        )
        let events = await reader.recentEvents()
        #expect(!events.isEmpty)
        #expect(events.count < 200)
        #expect(events.first?.id == "e199")
        #expect(events.allSatisfy { $0.title == "ws" })
    }

    @Test func corruptLinesAreSkippedOnLoad() async throws {
        let fileURL = try makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let writer = VaultHistoryEventStore(fileURL: fileURL)
        #expect(await writer.append(event(id: "good", secondsAgo: 60)))

        let handle = try FileHandle(forWritingTo: fileURL)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json at all\n".utf8))
        try handle.close()

        let reloaded = VaultHistoryEventStore(fileURL: fileURL)
        #expect(await reloaded.recentEvents().map(\.id) == ["good"])
    }
}
