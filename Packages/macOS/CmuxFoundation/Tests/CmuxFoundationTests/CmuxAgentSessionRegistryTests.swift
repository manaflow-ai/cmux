import Foundation
import SQLite3
import Testing
@testable import CmuxFoundation

@Suite("Agent session registry")
struct CmuxAgentSessionRegistryTests {
    @Test("legacy rewrites cannot erase current session metadata")
    func legacyRewriteDoesNotEraseCurrentMetadata() throws {
        let fixture = try Fixture()
        let current = try fixture.record(
            sessionID: "codex-current",
            updatedAt: 20,
            generation: 1,
            extra: ["cmuxRuntime": ["id": "tagged-runtime"], "runs": [["runId": "run-1"]]]
        )
        try fixture.registry.apply(provider: "codex", records: [current])

        let legacy = try fixture.legacyStore(
            sessions: ["codex-current": fixture.object(sessionID: "codex-current", updatedAt: 21)]
        )
        let stamp = CmuxAgentSessionRegistry.LegacyStamp(
            path: fixture.directory.appendingPathComponent("codex-hook-sessions.json").path,
            size: Int64(legacy.count),
            modifiedAt: 21
        )
        try fixture.registry.importLegacyStoreJSON(provider: "codex", stamp: stamp, json: legacy)

        let stored = try #require(fixture.registry.snapshot(provider: "codex").records.first)
        let object = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])
        let runtime = try #require(object["cmuxRuntime"] as? [String: Any])
        #expect(runtime["id"] as? String == "tagged-runtime")
        #expect(stored.writerGeneration == 1)
    }

    @Test("older registry generations cannot replace future rows")
    func writerGenerationIsMonotonic() throws {
        let fixture = try Fixture()
        try fixture.registry.apply(provider: "claude", records: [
            try fixture.record(
                sessionID: "future",
                updatedAt: 30,
                generation: 2,
                extra: ["futureState": "watching"]
            ),
        ])
        try fixture.registry.apply(provider: "claude", records: [
            try fixture.record(sessionID: "future", updatedAt: 40, generation: 1),
        ])

        let stored = try #require(fixture.registry.snapshot(provider: "claude").records.first)
        let object = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])
        #expect(object["futureState"] as? String == "watching")
        #expect(stored.writerGeneration == 2)
    }

    @Test("partial legacy snapshots cannot erase the last complete import")
    func partialLegacySnapshotDoesNotReplaceCompleteImport() throws {
        let fixture = try Fixture()
        let original = try fixture.legacyStore(
            sessions: ["durable": fixture.object(sessionID: "durable", updatedAt: 10)]
        )
        try fixture.registry.importLegacyStoreJSON(
            provider: "codex",
            stamp: CmuxAgentSessionRegistry.LegacyStamp(path: "legacy", size: Int64(original.count), modifiedAt: 10),
            json: original
        )
        let partial = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "sessions": [
                "durable": fixture.object(sessionID: "durable", updatedAt: 11),
                "partial": "incomplete-record",
            ],
        ])

        #expect(throws: (any Error).self) {
            try fixture.registry.importLegacyStoreJSON(
                provider: "codex",
                stamp: CmuxAgentSessionRegistry.LegacyStamp(path: "legacy", size: Int64(partial.count), modifiedAt: 11),
                json: partial
            )
        }
        let snapshot = try fixture.registry.snapshot(provider: "codex")
        #expect(snapshot.records.map(\.sessionID) == ["durable"])
        #expect(snapshot.records.first?.updatedAt == 10)
    }

    @Test("lifecycle patches preserve unknown future keys")
    func patchPreservesUnknownKeys() throws {
        let fixture = try Fixture()
        try fixture.registry.apply(provider: "opencode", records: [
            try fixture.record(
                sessionID: "patched",
                updatedAt: 10,
                generation: 2,
                extra: ["futureWorkload": ["monitor": true]]
            ),
        ])

        let patched = try fixture.registry.patchRecord(
            provider: "opencode",
            sessionID: "patched",
            updatedAt: 50
        ) { object in
            object["sessionState"] = "hibernated"
            object["updatedAt"] = 50
        }

        #expect(patched)
        let stored = try #require(fixture.registry.snapshot(provider: "opencode").records.first)
        let object = try #require(JSONSerialization.jsonObject(with: stored.json) as? [String: Any])
        #expect((object["futureWorkload"] as? [String: Any])?["monitor"] as? Bool == true)
        #expect(object["sessionState"] as? String == "hibernated")
        #expect(stored.writerGeneration == 2)
    }

    @Test("lifecycle patches promote imported legacy rows")
    func patchPromotesLegacyWriterGeneration() throws {
        let fixture = try Fixture()
        try fixture.registry.apply(provider: "codex", records: [
            try fixture.record(sessionID: "legacy", updatedAt: 10, generation: 0),
        ])

        let patched = try fixture.registry.patchRecord(
            provider: "codex",
            sessionID: "legacy",
            updatedAt: 20
        ) { object in
            object["sessionState"] = "hibernated"
            object["updatedAt"] = 20
        }

        #expect(patched)
        let stored = try #require(fixture.registry.snapshot(provider: "codex").records.first)
        #expect(stored.writerGeneration == CmuxAgentSessionRegistry.currentWriterGeneration)
    }

    @Test("one thousand indexed session rows load within a bounded interval")
    func indexedSnapshotPerformance() throws {
        let fixture = try Fixture()
        let records = try (0..<1_000).map { index in
            try fixture.record(sessionID: "session-\(index)", updatedAt: Double(index), generation: 1)
        }
        try fixture.registry.apply(provider: "codex", records: records)

        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            let snapshot = try fixture.registry.snapshot(provider: "codex")
            #expect(snapshot.records.count == 1_000)
        }
        #expect(elapsed < .seconds(1))
    }

    @Test("WAL snapshots stay readable while another connection owns the writer lock")
    func snapshotDoesNotJoinWriterContention() throws {
        let fixture = try Fixture(busyTimeoutMilliseconds: 10)
        try fixture.registry.apply(provider: "codex", records: [
            try fixture.record(sessionID: "committed", updatedAt: 1, generation: 1),
        ])

        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.registry.url.path, &database) == SQLITE_OK)
        let writer = try #require(database)
        defer { sqlite3_close(writer) }
        #expect(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
        defer { sqlite3_exec(writer, "ROLLBACK", nil, nil, nil) }

        let snapshot = try fixture.registry.snapshot(provider: "codex")
        #expect(snapshot.records.map(\.sessionID) == ["committed"])
    }

    private struct Fixture {
        let directory: URL
        let registry: CmuxAgentSessionRegistry

        init(busyTimeoutMilliseconds: Int32 = 100) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-agent-registry-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            registry = CmuxAgentSessionRegistry(
                url: directory.appendingPathComponent(CmuxAgentSessionRegistry.filename),
                busyTimeoutMilliseconds: busyTimeoutMilliseconds
            )
        }

        func object(sessionID: String, updatedAt: TimeInterval) -> [String: Any] {
            [
                "sessionId": sessionID,
                "workspaceId": "11111111-1111-1111-1111-111111111111",
                "surfaceId": "22222222-2222-2222-2222-222222222222",
                "startedAt": 1,
                "updatedAt": updatedAt,
            ]
        }

        func record(
            sessionID: String,
            updatedAt: TimeInterval,
            generation: Int,
            extra: [String: Any] = [:]
        ) throws -> CmuxAgentSessionRegistry.Record {
            let object = object(sessionID: sessionID, updatedAt: updatedAt).merging(extra) { _, new in new }
            return CmuxAgentSessionRegistry.Record(
                provider: "test",
                sessionID: sessionID,
                updatedAt: updatedAt,
                writerGeneration: generation,
                json: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        }

        func legacyStore(sessions: [String: [String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": 2, "sessions": sessions], options: [.sortedKeys])
        }
    }
}
