import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("WorkstreamPersistence")
struct WorkstreamPersistenceTests {
    @Test("Pending snapshot round-trips items oldest-first")
    func snapshotRoundTrip() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let persistence = WorkstreamPersistence(fileURL: fixture.url)
        let items = (0..<5).map(Self.pendingItem)

        try await persistence.replacePendingItems(items, generation: 1)

        let loaded = try await persistence.loadRecent(limit: 10)
        #expect(loaded.map(\.workstreamId) == ["s0", "s1", "s2", "s3", "s4"])
    }

    @Test("Snapshot item limit keeps the most recent pending suffix")
    func snapshotItemLimit() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let persistence = WorkstreamPersistence(
            fileURL: fixture.url,
            maximumItemCount: 2
        )

        try await persistence.replacePendingItems(
            (0..<5).map(Self.pendingItem),
            generation: 1
        )

        let loaded = try await persistence.loadRecent(limit: 10)
        #expect(loaded.map(\.workstreamId) == ["s3", "s4"])
    }

    @Test("Stale asynchronous generations cannot resurrect older pending state")
    func staleGenerationIgnored() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let persistence = WorkstreamPersistence(fileURL: fixture.url)

        try await persistence.replacePendingItems([Self.pendingItem(1)], generation: 2)
        try await persistence.replacePendingItems([Self.pendingItem(0)], generation: 1)

        #expect(try await persistence.loadRecent(limit: 10).map(\.workstreamId) == ["s1"])
    }

    @Test("Snapshot filters telemetry and resolved history")
    func snapshotFiltersHistory() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let persistence = WorkstreamPersistence(fileURL: fixture.url)
        let resolved = WorkstreamItem(
            workstreamId: "resolved",
            source: .claude,
            kind: .question,
            status: .resolved(.question(selections: ["Done"]), at: Date()),
            payload: .question(requestId: "resolved", questions: [])
        )
        let telemetry = WorkstreamItem(
            workstreamId: "telemetry",
            source: .claude,
            kind: .toolUse,
            payload: .toolUse(toolName: "Read", toolInputJSON: "{}")
        )

        try await persistence.replacePendingItems(
            [telemetry, resolved, Self.pendingItem(0)],
            generation: 1
        )

        #expect(try await persistence.loadRecent(limit: 10).map(\.workstreamId) == ["s0"])
    }

    @Test("Snapshot redacts sensitive tool input")
    func snapshotRedactsSensitiveToolInput() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let persistence = WorkstreamPersistence(fileURL: fixture.url)
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let item = WorkstreamItem(
            workstreamId: "s",
            source: .claude,
            kind: .permissionRequest,
            payload: .permissionRequest(
                requestId: "r",
                toolName: "Bash",
                toolInputJSON: #"{"command":"OPENAI_API_KEY=sk-test node \#(homePath)/app.js","env":{"SECRET":"value"}}"#,
                pattern: nil
            )
        )

        try await persistence.replacePendingItems([item], generation: 1)

        let loaded = try await persistence.loadRecent(limit: 1)
        guard case .permissionRequest(_, _, let toolInputJSON, _) = loaded[0].payload else {
            Issue.record("expected permission payload")
            return
        }
        #expect(!toolInputJSON.contains("sk-test"))
        #expect(!toolInputJSON.contains(#""value""#))
        #expect(toolInputJSON.contains("<redacted>"))
        let data = try #require(toolInputJSON.data(using: .utf8))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect((object["command"] as? String)?.contains("~/app.js") == true)
    }

    @Test("Missing file and non-positive limits return empty")
    func emptyReads() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let persistence = WorkstreamPersistence(fileURL: fixture.url)
        #expect(try await persistence.loadRecent(limit: 10).isEmpty)
        try await persistence.replacePendingItems([Self.pendingItem(0)], generation: 1)
        #expect(try await persistence.loadRecent(limit: 0).isEmpty)
    }

    @Test("Clear removes the backing file")
    func clearRemovesFile() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let persistence = WorkstreamPersistence(fileURL: fixture.url)
        try await persistence.replacePendingItems([Self.pendingItem(0)], generation: 1)
        #expect(FileManager.default.fileExists(atPath: fixture.url.path))
        try await persistence.clear()
        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
    }

    @Test("Persisted Feed state stays below the disk byte ceiling")
    func persistedStateHasByteCeiling() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let persistence = WorkstreamPersistence(fileURL: fixture.url)
        let largeInput = String(repeating: "x", count: 64 * 1024)
        let items = (0..<100).map { i in
            WorkstreamItem(
                workstreamId: "s\(i)",
                source: .claude,
                kind: .permissionRequest,
                payload: .permissionRequest(
                    requestId: "r\(i)",
                    toolName: "Bash",
                    toolInputJSON: largeInput,
                    pattern: nil
                )
            )
        }

        try await persistence.replacePendingItems(items, generation: 1)

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.url.path)
        let fileSize = try #require(attributes[.size] as? NSNumber).intValue
        #expect(fileSize <= WorkstreamDefaultPersistedByteLimit)
        #expect(try await persistence.loadRecent(limit: 100).last?.workstreamId == "s99")
    }

    private static func pendingItem(_ index: Int) -> WorkstreamItem {
        WorkstreamItem(
            workstreamId: "s\(index)",
            source: .claude,
            kind: .permissionRequest,
            payload: .permissionRequest(
                requestId: "r\(index)",
                toolName: "Write",
                toolInputJSON: "{}",
                pattern: nil
            )
        )
    }
}

private struct Fixture {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("cmux-workstream-\(UUID().uuidString).jsonl")

    func remove() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(
            at: WorkstreamPersistence.removedItemsFileURL(for: url)
        )
    }
}
