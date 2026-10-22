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

    @Test("bounded startup skips an unterminated oversized tail row")
    func startupSkipsPartialTailRow() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-partial-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let item = WorkstreamItem(
            workstreamId: "valid",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(item)
        data.append(0x0A)
        data.append(Data(repeating: 0x78, count: 1024 * 1024))
        try data.write(to: tmp)

        let persistence = WorkstreamPersistence(fileURL: tmp)
        let snapshot = try await persistence.loadStartupSnapshot(limit: 10)
        #expect(snapshot.items.map(\.workstreamId) == ["valid"])
    }

    @Test("bounded startup drops a partial head row past the byte budget")
    func startupDropsPartialHeadRowPastByteBudget() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-partial-head-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let item = WorkstreamItem(
            workstreamId: "valid",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data(repeating: 0x78, count: 33 * 1024 * 1024)
        data.append(0x0A)
        data.append(try encoder.encode(item))
        data.append(0x0A)
        try data.write(to: tmp)

        let snapshot = try await WorkstreamPersistence(fileURL: tmp)
            .loadStartupSnapshot(limit: 10)
        #expect(snapshot.items.map(\.workstreamId) == ["valid"])
        #expect(snapshot.page.hasMoreBefore)
        #expect(snapshot.revision == data.count)
    }

    @Test("an oversized malformed row cannot hide older valid history")
    func oversizedMalformedRowPreservesOlderCursor() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-oversized-middle-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let old = WorkstreamItem(
            workstreamId: "old",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        )
        let newest = WorkstreamItem(
            workstreamId: "new",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        )
        var data = try encoder.encode(old)
        data.append(0x0A)
        data.append(Data(repeating: 0x78, count: 9 * 1024 * 1024))
        data.append(0x0A)
        data.append(try encoder.encode(newest))
        data.append(0x0A)
        try data.write(to: tmp)

        let persistence = WorkstreamPersistence(fileURL: tmp)
        let snapshot = try await persistence.loadStartupSnapshot(limit: 1)
        #expect(snapshot.items.map(\.workstreamId) == ["new"])
        var cursor = try #require(snapshot.page.startOffset)
        var foundOld = false
        for _ in 0..<4 {
            let page = try await persistence.loadPage(endingBefore: cursor, limit: 1)
            if page.items.contains(where: { $0.workstreamId == "old" }) {
                foundOld = true
                break
            }
            guard page.hasMoreBefore, let next = page.startOffset, next < cursor else {
                break
            }
            cursor = next
        }
        #expect(foundOld)
    }

    @Test("an oversized unterminated tail preserves an older-history cursor")
    func oversizedUnterminatedTailPreservesOlderCursor() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-oversized-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let item = WorkstreamItem(
            workstreamId: "old",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(item)
        data.append(0x0A)
        data.append(Data(repeating: 0x78, count: 9 * 1024 * 1024))
        try data.write(to: tmp)

        let persistence = WorkstreamPersistence(fileURL: tmp)
        let snapshot = try await persistence.loadStartupSnapshot(limit: 1)
        #expect(snapshot.items.isEmpty)
        var cursor = try #require(snapshot.page.startOffset)
        var foundOld = false
        for _ in 0..<4 {
            let page = try await persistence.loadPage(endingBefore: cursor, limit: 1)
            if page.items.contains(where: { $0.workstreamId == "old" }) {
                foundOld = true
                break
            }
            guard page.hasMoreBefore, let next = page.startOffset, next < cursor else {
                break
            }
            cursor = next
        }
        #expect(foundOld)
    }

    @Test("valid rows below the bounded row limit remain restorable")
    func validLargeRowRemainsRestorable() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-large-valid-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let item = WorkstreamItem(
            workstreamId: "large-valid",
            source: .claude,
            kind: .permissionRequest,
            payload: .permissionRequest(
                requestId: "large",
                toolName: "Write",
                toolInputJSON: String(repeating: "x", count: 2 * 1024 * 1024),
                pattern: nil
            )
        )
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(item)
        let snapshot = try await persistence.loadStartupSnapshot(limit: 1)
        #expect(snapshot.items.map(\.workstreamId) == ["large-valid"])
    }

    @Test("repeated pages cross a complete row larger than the scan budget")
    func repeatedPagesCrossOversizedCompleteRow() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-oversized-progress-\(UUID().uuidString).jsonl")
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
                toolInputJSON: String(repeating: "x", count: 33 * 1024 * 1024)
            )
        ))
        try await persistence.append(WorkstreamItem(
            workstreamId: "new",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        var cursor = try #require((try await persistence.loadPage(limit: 1)).startOffset)
        var foundOld = false
        for _ in 0..<8 {
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

    @Test("consecutive oversized rows keep each page request bounded")
    func consecutiveOversizedRowsKeepPageBounded() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-oversized-consecutive-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "old",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))
        for id in ["oversized-a", "oversized-b"] {
            try await persistence.append(WorkstreamItem(
                workstreamId: id,
                source: .claude,
                kind: .toolUse,
                payload: .toolUse(
                    toolName: "Write",
                    toolInputJSON: String(repeating: "x", count: 9 * 1024 * 1024)
                )
            ))
        }
        try await persistence.append(WorkstreamItem(
            workstreamId: "new",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        var cursor = try #require((try await persistence.loadPage(limit: 1)).startOffset)
        var foundOld = false
        for _ in 0..<8 {
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

    @Test("exact bounded-window row boundaries retain the first row")
    func exactWindowBoundaryRetainsRow() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-boundary-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let first = WorkstreamItem(
            workstreamId: "first",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        )
        // The row itself may use the full 8 MiB cap; the bounded reader must
        // also admit its terminating newline.
        let targetRowBytes = 8 * 1024 * 1024 + 1
        var payloadSize = targetRowBytes
        var secondData = Data()
        while true {
            let second = WorkstreamItem(
                workstreamId: "second",
                source: .claude,
                kind: .toolUse,
                payload: .toolUse(
                    toolName: "Write",
                    toolInputJSON: String(repeating: "x", count: payloadSize)
                )
            )
            secondData = try encoder.encode(second)
            let delta = targetRowBytes - (secondData.count + 1)
            if delta == 0 { break }
            payloadSize = max(0, payloadSize + delta)
        }
        #expect(secondData.count + 1 == targetRowBytes)
        var data = try encoder.encode(first)
        data.append(0x0A)
        let secondStart = UInt64(data.count)
        data.append(secondData)
        data.append(0x0A)
        try data.write(to: tmp)

        let page = try await WorkstreamPersistence(fileURL: tmp)
            .loadPage(endingBefore: secondStart + UInt64(targetRowBytes), limit: 1)
        #expect(page.items.map(\.workstreamId) == ["second"])
    }

    @Test("startup retains a row at the exact bounded-tail boundary")
    func startupExactWindowBoundaryRetainsRow() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-startup-boundary-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let target = WorkstreamItem(
            workstreamId: "startup-boundary",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data("old\n".utf8)
        data.append(try encoder.encode(target))
        data.append(0x0A)
        let trailingBytes = 8 * 1024 * 1024
        #expect(data.count < trailingBytes)
        data.append(Data(repeating: 0x78, count: trailingBytes - data.count - 1))
        data.append(0x0A)
        try data.write(to: tmp)

        let snapshot = try await WorkstreamPersistence(fileURL: tmp)
            .loadStartupSnapshot(limit: 1)
        #expect(snapshot.items.map(\.workstreamId) == ["startup-boundary"])
    }

    @Test("startup reports bounded-load diagnostics")
    func startupReportsDiagnostics() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-diagnostics-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "s",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        let snapshot = try await persistence.loadStartupSnapshot(
            limit: 10,
            budgetNanoseconds: 0
        )
        #expect(snapshot.diagnostics.fileBytes > 0)
        #expect(snapshot.diagnostics.exceededBudget)
        #expect(!snapshot.diagnostics.missingFile)
    }

    @Test("missing startup file is distinguished from an empty successful load")
    func missingStartupDiagnostics() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-missing-diagnostics-\(UUID().uuidString).jsonl")
        let snapshot = try await WorkstreamPersistence(fileURL: tmp)
            .loadStartupSnapshot(limit: 10)
        #expect(snapshot.items.isEmpty)
        #expect(snapshot.diagnostics.missingFile)
        #expect(snapshot.diagnostics.fileBytes == 0)
    }

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
