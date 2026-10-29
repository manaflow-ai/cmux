import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Workstream recovery mutations")
@MainActor
struct WorkstreamRecoveryMutationTests {
    @Test("Recovery preserves the exact newest status and reply", arguments: [false, true])
    func latestMutationSurvivesRecovery(oversizedTail: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workstream.jsonl")
        let persistence = WorkstreamPersistence(fileURL: url)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var item = WorkstreamItem(
            workstreamId: "session", source: .claude, kind: .permissionRequest,
            createdAt: timestamp, status: .pending,
            payload: .permissionRequest(requestId: "request", toolName: "Write", toolInputJSON: "{}", pattern: nil)
        )
        try await persistence.append(item)
        let other = WorkstreamItem(
            workstreamId: "other", source: .claude, kind: .sessionStart,
            createdAt: timestamp, payload: .sessionStart
        )
        try await persistence.append(other)
        item.status = .resolved(.permission(.deny), at: timestamp)
        item.reply = WorkstreamReply(text: "do not write", createdAt: timestamp)
        try await persistence.append(item)
        if oversizedTail {
            let writer = try FileHandle(forWritingTo: url)
            defer { try? writer.close() }
            try writer.seekToEnd()
            try writer.write(contentsOf: Data(repeating: 0x78, count: 9 * 1024 * 1024))
            try writer.write(contentsOf: Data([0x0A]))
            let snapshot = try await persistence.loadStartupSnapshot(limit: 10)
            #expect(snapshot.items == [other, item])
            #expect(snapshot.page.items == snapshot.items)
        }
        let store = WorkstreamStore(
            persistence: persistence, initialLoadLimit: 10,
            startupHardBudgetNanoseconds: oversizedTail ? nil : 0
        )
        await store.start()
        if !oversizedTail {
            #expect(store.items.isEmpty)
            #expect(store.hasMorePersistedItems)
            await store.loadOlderItems()
        }
        #expect(store.items == [other, item])
        #expect(store.pending.isEmpty)
        #expect(!store.hasMorePersistedItems)
        await store.flushPersistence()
    }

    @Test("A later history page cannot resurrect an older pending mutation")
    func laterPagesKeepNewestMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = WorkstreamPersistence(fileURL: directory.appendingPathComponent("workstream.jsonl"))
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var item = WorkstreamItem(
            workstreamId: "session", source: .claude, kind: .permissionRequest,
            createdAt: timestamp, status: .pending,
            payload: .permissionRequest(requestId: "request", toolName: "Write", toolInputJSON: "{}", pattern: nil)
        )
        try await persistence.append(item)
        item.status = .resolved(.permission(.once), at: timestamp)
        try await persistence.append(item)
        let store = WorkstreamStore(persistence: persistence, historyPageSize: 1, startupHardBudgetNanoseconds: 0)
        await store.start()
        await store.loadOlderItems()
        #expect(store.items == [item])
        #expect(store.hasMorePersistedItems)
        await store.loadOlderItems()
        #expect(store.items == [item])
        #expect(!store.hasMorePersistedItems)
        await store.flushPersistence()
    }

    @Test("Oversized revision metadata is rejected rather than read without a bound")
    func oversizedRevisionMetadataIsIgnored() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workstream.jsonl")
        try Data(("42" + String(repeating: " ", count: 4096)).utf8)
            .write(to: url.appendingPathExtension("revision"))
        #expect(try await WorkstreamPersistence(fileURL: url).loadRevision() == 0)
    }
}
