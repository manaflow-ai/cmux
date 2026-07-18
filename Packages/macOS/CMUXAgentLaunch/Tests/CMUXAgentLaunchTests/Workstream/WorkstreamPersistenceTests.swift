import Foundation
import SQLite3
import Testing
@testable import CMUXAgentLaunch

@Suite("WorkstreamPersistence")
struct WorkstreamPersistenceTests {
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

    @Test("Acknowledged retries keep one stable UUID and one history row")
    func acknowledgedRetryIsDurablyIdempotent() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let event = fixture.event(requestID: "delivery-1")
        let persistence = fixture.persistence()

        let firstID = try await persistence.appendAcknowledged(fixture.item(for: event), for: event)
        let retryID = try await persistence.appendAcknowledged(fixture.item(for: event), for: event)

        #expect(retryID == firstID)
        let loaded = try await persistence.loadRecent(limit: 10)
        #expect(loaded.map(\.id) == [firstID])
    }

    @Test("Raw composite request columns do not collide")
    func compositeRequestIdentityDoesNotCollide() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let persistence = fixture.persistence()
        let events = [
            fixture.event(sessionID: "session-a", eventName: .preToolUse, source: "codex", requestID: "same"),
            fixture.event(sessionID: "session-b", eventName: .preToolUse, source: "codex", requestID: "same"),
            fixture.event(sessionID: "session-a", eventName: .postToolUse, source: "codex", requestID: "same"),
            fixture.event(sessionID: "session-a", eventName: .preToolUse, source: "claude", requestID: "same"),
            fixture.event(sessionID: "session-a\0suffix", eventName: .preToolUse, source: "codex", requestID: "nul"),
            fixture.event(sessionID: "session-a", eventName: .preToolUse, source: "codex", requestID: "nul"),
        ]

        var ids = Set<UUID>()
        for event in events {
            ids.insert(try await persistence.appendAcknowledged(fixture.item(for: event), for: event))
        }

        #expect(ids.count == events.count)
        #expect(try await persistence.loadRecent(limit: 10).count == events.count)
    }

    @Test("Append-before-flag recovery finds the stable UUID without duplicating JSONL")
    func appendBeforeFlagRecoveryIsExactlyOnce() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let event = fixture.event(requestID: "interrupted-after-append")
        let persistence = fixture.persistence()
        let firstID = try await persistence.appendAcknowledged(fixture.item(for: event), for: event)
        try fixture.executeReceiptSQL(
            "UPDATE feed_receipts SET appended = 0 WHERE item_id = '\(firstID.uuidString)';"
        )

        let retryID = try await persistence.appendAcknowledged(fixture.item(for: event), for: event)

        #expect(retryID == firstID)
        #expect(try await persistence.loadRecent(limit: 10).map(\.id) == [firstID])
        #expect(try fixture.receiptAppended(itemID: firstID))
    }

    @Test("Interrupted partial JSONL append is isolated before recovery appends")
    func partialHistoryAppendRecoveryRestoresOneValidRow() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let event = fixture.event(requestID: "interrupted-mid-line")
        let persistence = fixture.persistence()
        let itemID = try await persistence.appendAcknowledged(fixture.item(for: event), for: event)
        try fixture.executeReceiptSQL(
            "UPDATE feed_receipts SET appended = 0 WHERE item_id = '\(itemID.uuidString)';"
        )
        let historyHandle = try FileHandle(forUpdating: fixture.historyURL)
        let originalSize = try historyHandle.seekToEnd()
        try historyHandle.truncate(atOffset: originalSize / 2)
        try historyHandle.close()

        let recoveredID = try await persistence.appendAcknowledged(fixture.item(for: event), for: event)

        #expect(recoveredID == itemID)
        #expect(try await persistence.loadRecent(limit: 10).map(\.id) == [itemID])
    }

    @Test("Expired receipt retry after an acknowledgement loss keeps one history row")
    func expiredReceiptRetryKeepsDeterministicUUID() async throws {
        let clock = ReceiptTestClock(now: Date(timeIntervalSince1970: 10_000))
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let event = fixture.event(
            requestID: "delivered-before-long-outage",
            receivedAt: clock.now
        )
        let persistence = fixture.persistence(
            receiptRetention: 100,
            maximumReceiptCount: 1,
            clock: { clock.now }
        )
        let firstID = try await persistence.appendAcknowledged(fixture.item(for: event), for: event)

        clock.advance(101)
        let replacement = fixture.event(
            requestID: "replacement-that-prunes-expired-receipt",
            receivedAt: clock.now
        )
        _ = try await persistence.appendAcknowledged(fixture.item(for: replacement), for: replacement)
        clock.advance(101)
        let retryID = try await persistence.appendAcknowledged(fixture.item(for: event), for: event)

        #expect(retryID == firstID)
        let history = try await persistence.loadRecent(limit: 10)
        #expect(history.filter { $0.id == firstID }.count == 1)
    }

    @Test("Receipt retention slides on retry and count pressure never evicts it")
    func retrySlidesRetentionUnderCountPressure() async throws {
        let clock = ReceiptTestClock(now: Date(timeIntervalSince1970: 20_000))
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let persistence = fixture.persistence(
            receiptRetention: 100,
            maximumReceiptCount: 1,
            clock: { clock.now }
        )
        let first = fixture.event(requestID: "live-retry", receivedAt: clock.now)
        let firstID = try await persistence.appendAcknowledged(fixture.item(for: first), for: first)

        clock.advance(60)
        #expect(try await persistence.appendAcknowledged(fixture.item(for: first), for: first) == firstID)
        clock.advance(60)
        let second = fixture.event(requestID: "new-at-capacity", receivedAt: clock.now)
        await #expect(throws: WorkstreamPersistenceError.receiptCountLimitReached(maximumCount: 1)) {
            try await persistence.appendAcknowledged(fixture.item(for: second), for: second)
        }
        #expect(try await persistence.appendAcknowledged(fixture.item(for: first), for: first) == firstID)

        clock.advance(101)
        _ = try await persistence.appendAcknowledged(fixture.item(for: second), for: second)
        #expect(try await persistence.loadRecent(limit: 10).count == 2)
    }

    @Test("Receipt database applies byte backpressure while existing retries stay live")
    func receiptDatabaseIsByteBounded() async throws {
        let maximumBytes: Int64 = 128 * 1_024
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let persistence = fixture.persistence(
            maximumReceiptCount: 10_000,
            maximumReceiptStoreBytes: maximumBytes
        )
        let first = fixture.event(requestID: "first-live-receipt")
        let firstID = try await persistence.appendAcknowledged(fixture.item(for: first), for: first)

        var sawByteBackpressure = false
        for index in 0..<500 {
            let event = fixture.event(
                sessionID: "session-\(String(repeating: "s", count: 512))-\(index)",
                requestID: "request-\(String(repeating: "r", count: 512))-\(index)"
            )
            do {
                _ = try await persistence.appendAcknowledged(fixture.item(for: event), for: event)
            } catch WorkstreamPersistenceError.receiptByteLimitReached(let bound) {
                #expect(bound == maximumBytes)
                sawByteBackpressure = true
                break
            }
        }

        #expect(sawByteBackpressure)
        #expect(try await persistence.appendAcknowledged(fixture.item(for: first), for: first) == firstID)
        #expect(fixture.receiptStoreBytes <= maximumBytes)
    }

    @Test("Clear removes receipts with history so the same event can be admitted again")
    func clearRemovesReceiptsAndHistory() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let persistence = fixture.persistence()
        let event = fixture.event(requestID: "clear-and-retry")
        let item = fixture.item(for: event)
        let originalID = try await persistence.appendAcknowledged(item, for: event)

        try await persistence.clear()
        #expect(try await persistence.loadRecent(limit: 10).isEmpty)

        let readmittedID = try await persistence.appendAcknowledged(item, for: event)
        #expect(readmittedID == originalID)
        #expect(try await persistence.loadRecent(limit: 10).map(\.id) == [originalID])
    }

    @Test("250 acknowledged appends complete with fully synchronized receipts")
    func acknowledgedAppendThroughputSample() async throws {
        let fixture = try ReceiptFixture()
        defer { fixture.remove() }
        let persistence = fixture.persistence()

        for index in 0..<250 {
            let event = fixture.event(requestID: "throughput-\(index)")
            _ = try await persistence.appendAcknowledged(fixture.item(for: event), for: event)
        }

        #expect(try await persistence.loadRecent(limit: 300).count == 250)
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
}

private struct ReceiptFixture {
    let directory: URL
    let historyURL: URL
    let receiptDatabaseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-receipts-\(UUID().uuidString)", isDirectory: true)
        historyURL = directory.appendingPathComponent("workstream.jsonl")
        receiptDatabaseURL = directory.appendingPathComponent("receipts.sqlite3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func persistence(
        receiptRetention: TimeInterval = 24 * 60 * 60,
        maximumReceiptCount: Int = 100_000,
        maximumReceiptStoreBytes: Int64 = 64 * 1_024 * 1_024,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> WorkstreamPersistence {
        WorkstreamPersistence(
            fileURL: historyURL,
            receiptDatabaseURL: receiptDatabaseURL,
            receiptRetention: receiptRetention,
            maximumReceiptCount: maximumReceiptCount,
            maximumReceiptStoreBytes: maximumReceiptStoreBytes,
            clock: clock
        )
    }

    func event(
        sessionID: String = "session-a",
        eventName: WorkstreamEvent.HookEventName = .preToolUse,
        source: String = "codex",
        requestID: String,
        receivedAt: Date = Date()
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: eventName,
            source: source,
            toolName: "Read",
            toolInputJSON: #"{"path":"README.md"}"#,
            requestId: requestID,
            receivedAt: receivedAt
        )
    }

    func item(for event: WorkstreamEvent) -> WorkstreamItem {
        WorkstreamItem(
            workstreamId: event.sessionId,
            source: WorkstreamSource(wireName: event.source) ?? .claude,
            kind: event.hookEventName == .postToolUse ? .toolResult : .toolUse,
            requestId: event.requestId,
            createdAt: event.receivedAt,
            payload: .toolUse(toolName: event.toolName ?? "Read", toolInputJSON: event.toolInputJSON ?? "{}")
        )
    }

    func executeReceiptSQL(_ sql: String) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            receiptDatabaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "ReceiptFixture", code: Int(openStatus))
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 1_000)
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw NSError(domain: "ReceiptFixture", code: Int(status))
        }
    }

    func receiptAppended(itemID: UUID) throws -> Bool {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            receiptDatabaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw NSError(domain: "ReceiptFixture", code: Int(openStatus))
        }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        let sql = "SELECT appended FROM feed_receipts WHERE item_id = ?;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw NSError(domain: "ReceiptFixture", code: 1) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, itemID.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "ReceiptFixture", code: 2)
        }
        return sqlite3_column_int(statement, 0) != 0
    }

    var receiptStoreBytes: Int64 {
        [
            receiptDatabaseURL,
            URL(fileURLWithPath: receiptDatabaseURL.path + "-wal"),
            URL(fileURLWithPath: receiptDatabaseURL.path + "-shm"),
        ]
            .reduce(into: Int64(0)) { total, url in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attributes[.size] as? NSNumber
                else { return }
                total += size.int64Value
            }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ReceiptTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) {
        value = now
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}
