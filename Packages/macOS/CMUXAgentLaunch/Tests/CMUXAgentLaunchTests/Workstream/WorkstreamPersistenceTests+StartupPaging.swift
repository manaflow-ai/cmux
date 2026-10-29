import Foundation
import Testing
@testable import CMUXAgentLaunch

// Additional bounded journal recovery scenarios.
extension WorkstreamPersistenceTests {
    @Test("clear removes the backing file")
    func clearRemovesFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-clear-\(UUID().uuidString).jsonl")
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "s", source: .claude, kind: .sessionStart, payload: .sessionStart
        ))
        #expect(FileManager.default.fileExists(atPath: tmp.path))
        try await persistence.clear()
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
    }

    @Test("clear preserves a byte-count revision floor above the sidecar")
    func clearPreservesByteCountRevisionFloor() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-clear-revision-floor-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("revision"))
        }

        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.recordRevision(1)
        for index in 0..<4 {
            try await persistence.append(WorkstreamItem(
                workstreamId: String(repeating: "row-\(index)-", count: 128),
                source: .claude,
                kind: .sessionStart,
                payload: .sessionStart
            ))
        }
        let byteCountRevision = try await persistence.loadRevision()
        #expect(byteCountRevision > 1)

        try await persistence.clear()
        let restarted = WorkstreamPersistence(fileURL: tmp)
        #expect(try await restarted.loadRevision() == byteCountRevision)
    }

    @Test("Paging rows near the bounded read window loses no history")
    func pagingLargeOrdinaryRowsKeepsEveryRow() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-large-row-paging-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("revision"))
        }
        // About 30 KB per row: well under the oversized-row cap, but large
        // enough that 300 rows overflow one bounded read window, so a window
        // starts inside an ordinary row.
        let persistence = WorkstreamPersistence(fileURL: tmp)
        for index in 0..<700 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "row-\(index)",
                source: .claude,
                kind: .toolUse,
                payload: .toolUse(toolName: "Write", toolInputJSON: String(repeating: "x", count: 30_000))
            ))
        }

        var cursor: UInt64?
        var seen: [String] = []
        for _ in 0..<50 {
            let page = try await persistence.loadPage(endingBefore: cursor, limit: 300)
            seen.insert(contentsOf: page.items.map(\.workstreamId), at: 0)
            guard page.hasMoreBefore, let next = page.startOffset else { break }
            cursor = next
        }

        #expect(seen == (0..<700).map { "row-\($0)" })
    }

    @Test("A startup budget that expires mid-read loses no row")
    func startupBudgetExpiryKeepsEveryRowReachable() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-budget-cursor-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("revision"))
        }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        for index in 0..<3_000 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "row-\(index)",
                source: .claude,
                kind: .toolUse,
                payload: .toolUse(toolName: "Write", toolInputJSON: String(repeating: "x", count: 2_000))
            ))
        }
        let expected = (0..<3_000).map { "row-\($0)" }

        // Wherever the budget runs out (before the read, partway through
        // it, or partway through decoding), the published items plus the
        // pages before the cursor must still cover every row exactly once.
        for budget: UInt64 in [0, 50_000, 100_000, 250_000, 500_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000, 20_000_000] {
            let snapshot = try await persistence.loadStartupSnapshot(limit: 300, hardBudgetNanoseconds: budget)
            var seen = snapshot.items.map(\.workstreamId)
            var cursor = snapshot.page.startOffset
            var more = snapshot.page.hasMoreBefore
            for _ in 0..<100 where more {
                let page = try await persistence.loadPage(endingBefore: cursor, limit: 300)
                seen.insert(contentsOf: page.items.map(\.workstreamId), at: 0)
                more = page.hasMoreBefore
                cursor = page.startOffset
            }
            #expect(seen == expected, "budget \(budget) ns")
        }
    }

    @Test("An oversized newest row does not leave the startup Feed empty")
    func oversizedNewestRowStillPublishesOlderItems() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-oversized-newest-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("revision"))
        }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        for index in 0..<3 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "row-\(index)",
                source: .claude,
                kind: .sessionStart,
                payload: .sessionStart
            ))
        }
        // A complete row larger than the startup read window, such as a
        // huge Write tool input, is the newest row in the log.
        try await persistence.append(WorkstreamItem(
            workstreamId: "huge",
            source: .claude,
            kind: .toolUse,
            payload: .toolUse(toolName: "Write", toolInputJSON: String(repeating: "x", count: 9 * 1024 * 1024))
        ))

        let snapshot = try await persistence.loadStartupSnapshot(limit: 300)
        #expect(snapshot.items.map(\.workstreamId) == ["row-0", "row-1", "row-2"])
    }
}
