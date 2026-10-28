import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Workstream startup deadline")
struct WorkstreamStartupDeadlineTests {
    @Test("A deadline during latest-tail decode keeps partial rows pageable")
    @MainActor
    func partialLatestRowsKeepAnEOFCursor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.jsonl")
        let writer = WorkstreamPersistence(fileURL: url)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let old = WorkstreamItem(
            workstreamId: "old",
            source: .claude,
            kind: .sessionStart,
            createdAt: timestamp,
            payload: .sessionStart
        )
        let newest = WorkstreamItem(
            workstreamId: "newest",
            source: .claude,
            kind: .sessionStart,
            createdAt: timestamp,
            payload: .sessionStart
        )
        try await writer.append(old)
        try await writer.append(newest)

        let clock = AdvancingUptime()
        let persistence = WorkstreamPersistence(fileURL: url, uptimeNanoseconds: { clock.read() })
        let store = WorkstreamStore(
            persistence: persistence,
            initialLoadLimit: 10,
            startupHardBudgetNanoseconds: 3
        )
        await store.start()

        #expect(store.items.map(\.workstreamId) == ["newest"])
        #expect(store.hasMorePersistedItems)
        await store.loadOlderItems()
        #expect(store.items.map(\.workstreamId) == ["old", "newest"])
        #expect(!store.hasMorePersistedItems)
    }

    @Test("An expired oversized-tail pass leaves all valid history reachable", arguments: [
        1, 64, 130, 140, 260
    ])
    func deadlineStopsEveryFallbackPhase(budget: UInt64) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.jsonl")
        let writer = WorkstreamPersistence(fileURL: url)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let expected = (0..<3).map { index in
            WorkstreamItem(workstreamId: "row-\(index)", source: .claude, kind: .sessionStart,
                           createdAt: timestamp, payload: .sessionStart)
        }
        for item in expected { try await writer.append(item) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x78, count: 9 * 1024 * 1024))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()

        let clock = AdvancingUptime()
        let reader = WorkstreamPersistence(fileURL: url, uptimeNanoseconds: { clock.read() })
        let snapshot = try await reader.loadStartupSnapshot(limit: 10, hardBudgetNanoseconds: budget)
        #expect(snapshot.diagnostics.exceededBudget)
        #expect(snapshot.diagnostics.elapsedNanoseconds <= budget + 2)
        var recovered = snapshot.items
        var cursor = snapshot.page.startOffset
        var more = snapshot.page.hasMoreBefore
        for _ in 0..<10 where more {
            let page = try await reader.loadPage(endingBefore: cursor, limit: 10)
            recovered.insert(contentsOf: page.items, at: 0)
            cursor = page.startOffset
            more = page.hasMoreBefore
        }
        #expect(!more)
        // A partial startup tail intentionally overlaps the first page from
        // EOF. Reconcile by UUID exactly as WorkstreamStore does, then verify
        // that every expected row remains reachable in journal order.
        var seen = Set<UUID>()
        let uniqueRecovered = recovered.filter { seen.insert($0.id).inserted }
        #expect(uniqueRecovered == expected)
    }
}
