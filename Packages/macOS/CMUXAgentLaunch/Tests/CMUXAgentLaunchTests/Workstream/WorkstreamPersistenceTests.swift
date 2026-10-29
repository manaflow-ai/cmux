import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("WorkstreamPersistence")
struct WorkstreamPersistenceTests {
    @Test("Revision high-water survives a restart without a JSONL append")
    func revisionHighWaterSurvivesRestart() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-revision-floor-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("revision"))
        }

        let first = WorkstreamPersistence(fileURL: tmp)
        try await first.recordRevision(41)

        let restarted = WorkstreamPersistence(fileURL: tmp)
        #expect(try await restarted.loadRevision() == 41)
        try await restarted.recordRevision(7)
        #expect(try await restarted.loadRevision() == 41)

        try await restarted.clear()
        #expect(try await restarted.loadRevision() == 41)
    }

    @Test("An oversized revision sidecar is clamped without startup overflow")
    @MainActor
    func oversizedRevisionSidecarIsClamped() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-revision-overflow-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("revision"))
        }

        try Data("18446744073709551615\n".utf8)
            .write(to: tmp.appendingPathExtension("revision"))
        let persistence = WorkstreamPersistence(fileURL: tmp)
        #expect(try await persistence.loadRevision() == Int.max - 1)

        let store = WorkstreamStore(persistence: WorkstreamPersistence(fileURL: tmp))
        await store.start()
        #expect(store.revision == Int.max)
    }

    @Test("Append + loadRecent round-trips items oldest-first")
    func appendAndLoad() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let items = (0..<5).map { i in
            WorkstreamItem(
                workstreamId: "s\(i)",
                source: .claude,
                kind: .permissionRequest,
                payload: .permissionRequest(
                    requestId: "r\(i)",
                    toolName: "Write",
                    toolInputJSON: "{}",
                    pattern: nil
                )
            )
        }
        for item in items {
            try await persistence.append(item)
        }
        let loaded = try await persistence.loadRecent(limit: 10)
        #expect(loaded.count == 5)
        #expect(loaded.first?.workstreamId == "s0")
        #expect(loaded.last?.workstreamId == "s4")
    }

    @Test("append repairs a torn final JSONL row before writing")
    func appendRepairsTornFinalRow() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-torn-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let torn = WorkstreamItem(
            workstreamId: "torn",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        )
        try encoder.encode(torn).write(to: tmp)

        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "durable",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        let loaded = try await persistence.loadRecent(limit: 10)
        #expect(loaded.map(\.workstreamId) == ["torn", "durable"])
    }

    @Test("append preserves history when the torn row exceeds the decode budget")
    func appendSeparatesOversizedTornRow() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-oversized-torn-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let old = WorkstreamItem(
            workstreamId: "old",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(old)
        data.append(0x0A)
        data.append(Data(repeating: 0x78, count: 33 * 1024 * 1024))
        try data.write(to: tmp)

        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "durable",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))
        #expect((try await persistence.loadRecent(limit: 1)).map(\.workstreamId) == ["durable"])
        let newest = try await persistence.loadPage(limit: 1)
        var cursor = try #require(newest.startOffset)
        var foundOld = false
        for _ in 0..<4 {
            let page = try await persistence.loadPage(endingBefore: cursor, limit: 1)
            if page.items.contains(where: { $0.workstreamId == "old" }) {
                foundOld = true
                break
            }
            guard page.hasMoreBefore, let next = page.startOffset, next < cursor else { break }
            cursor = next
        }
        #expect(foundOld)
    }

    @Test("loadRecent with limit returns the most recent suffix")
    func loadRecentLimit() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        for i in 0..<5 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "s\(i)",
                source: .claude,
                kind: .permissionRequest,
                payload: .permissionRequest(requestId: "r\(i)", toolName: "t", toolInputJSON: "{}", pattern: nil)
            ))
        }
        let loaded = try await persistence.loadRecent(limit: 2)
        #expect(loaded.count == 2)
        #expect(loaded.first?.workstreamId == "s3")
        #expect(loaded.last?.workstreamId == "s4")
    }

    @Test("loadRecent skips a complete oversized row without losing older history")
    func loadRecentSkipsCompleteOversizedRow() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-oversized-complete-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "old",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))
        try await persistence.append(WorkstreamItem(
            workstreamId: "oversized",
            source: .claude,
            kind: .toolUse,
            payload: .toolUse(
                toolName: "Write",
                toolInputJSON: String(repeating: "x", count: 9 * 1024 * 1024)
            )
        ))
        try await persistence.append(WorkstreamItem(
            workstreamId: "new",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        let loaded = try await persistence.loadRecent(limit: 2)
        #expect(loaded.map(\.workstreamId) == ["old", "new"])
    }

    @Test("startup budget cutoff preserves an older-history cursor")
    func startupBudgetCutoffFailsClosedWithoutCursor() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-oversized-budget-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "old",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))
        try await persistence.append(WorkstreamItem(
            workstreamId: "oversized",
            source: .claude,
            kind: .toolUse,
            payload: .toolUse(
                toolName: "Write",
                toolInputJSON: String(repeating: "x", count: 9 * 1024 * 1024)
            )
        ))
        try await persistence.append(WorkstreamItem(
            workstreamId: "new",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        let snapshot = try await persistence.loadStartupSnapshot(
            limit: 2,
            hardBudgetNanoseconds: 0
        )
        #expect(snapshot.diagnostics.exceededBudget)
        #expect(snapshot.page.startOffset != nil)
        #expect(snapshot.page.hasMoreBefore)
    }

    @Test("loadPage pages older rows before a stable byte cursor")
    func loadPageBeforeCursor() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-page-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        for i in 0..<5 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "s\(i)",
                source: .claude,
                kind: .permissionRequest,
                payload: .permissionRequest(requestId: "r\(i)", toolName: "t", toolInputJSON: "{}", pattern: nil)
            ))
        }

        let newest = try await persistence.loadPage(limit: 2)
        #expect(newest.items.map(\.workstreamId) == ["s3", "s4"])
        #expect(newest.hasMoreBefore)
        let cursor = try #require(newest.startOffset)

        try await persistence.append(WorkstreamItem(
            workstreamId: "s5",
            source: .claude,
            kind: .permissionRequest,
            payload: .permissionRequest(requestId: "r5", toolName: "t", toolInputJSON: "{}", pattern: nil)
        ))

        let older = try await persistence.loadPage(endingBefore: cursor, limit: 2)
        #expect(older.items.map(\.workstreamId) == ["s1", "s2"])
        #expect(older.hasMoreBefore)
    }

    @Test("paging does not skip rows when a bounded read spans multiple chunks")
    func loadPageAcrossChunkBoundary() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-chunk-page-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        for i in 0..<1_000 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "s\(i)",
                source: .claude,
                kind: .sessionStart,
                payload: .sessionStart
            ))
        }

        var cursor: UInt64?
        var seen: [String] = []
        repeat {
            let page = try await persistence.loadPage(endingBefore: cursor, limit: 300)
            seen.insert(contentsOf: page.items.map(\.workstreamId), at: 0)
            cursor = page.startOffset
            if !page.hasMoreBefore { break }
        } while seen.count < 1_000

        #expect(seen.count == 1_000)
        #expect(Set(seen).count == 1_000)
        #expect(seen.first == "s0")
        #expect(seen.last == "s999")
    }

    @Test("append redacts sensitive tool input before writing JSONL")
    func appendRedactsSensitiveToolInput() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-redact-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        try await persistence.append(WorkstreamItem(
            workstreamId: "s",
            source: .claude,
            kind: .permissionRequest,
            payload: .permissionRequest(
                requestId: "r",
                toolName: "Bash",
                toolInputJSON: #"{"command":"OPENAI_API_KEY=sk-test node \#(homePath)/app.js","env":{"SECRET":"value"}}"#,
                pattern: nil
            )
        ))

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

    @Test("Missing file returns empty")
    func missingFileEmpty() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-missing-\(UUID().uuidString).jsonl")
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let loaded = try await persistence.loadRecent(limit: 10)
        #expect(loaded.isEmpty)
    }

    @Test("Non-positive limit returns empty")
    func nonPositiveLimitEmpty() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-limit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "s", source: .claude, kind: .sessionStart, payload: .sessionStart
        ))
        let loaded = try await persistence.loadRecent(limit: 0)
        #expect(loaded.isEmpty)
    }


}
