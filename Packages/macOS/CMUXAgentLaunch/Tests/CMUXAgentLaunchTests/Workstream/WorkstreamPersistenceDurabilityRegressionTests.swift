import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Workstream persistence durability regressions")
struct WorkstreamPersistenceDurabilityRegressionTests {
    @Test("History loading collapses duplicate stable UUID rows")
    func loadRecentDeduplicatesStableUUIDs() async throws {
        let historyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-duplicate-id-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: historyURL) }
        let persistence = WorkstreamPersistence(fileURL: historyURL)
        let item = WorkstreamItem(
            workstreamId: "legacy-duplicate",
            source: .codex,
            kind: .toolUse,
            requestId: "legacy-duplicate",
            payload: .toolUse(toolName: "Read", toolInputJSON: "{}")
        )
        try await persistence.append(item)
        try await persistence.append(item)

        #expect(try await persistence.loadRecent(limit: 10).map(\.id) == [item.id])
    }
}
