import Foundation
import Testing
@testable import CMUXAgentLaunch

// Additional bounded journal recovery scenarios.
extension WorkstreamPersistenceTests {
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


}
