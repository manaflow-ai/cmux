import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Workstream startup deadline")
struct WorkstreamStartupDeadlineTests {
    @Test("An expired oversized-tail pass leaves all valid history reachable", arguments: [
        UInt64(0), 1, 64, 130, 140, 260, 275
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
        #expect(recovered == expected)
    }
}
