import Foundation
import Testing
@testable import CMUXAgentLaunch

@MainActor
@Suite("WorkstreamStore")
struct WorkstreamStoreTests {
    @Test("ingest creates a pending item for permission requests")
    func ingestPending() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(.permission("s1", requestId: "r1"))
        #expect(store.items.count == 1)
        #expect(store.pending.count == 1)
        #expect(store.items[0].kind == .permissionRequest)
    }

    @Test("send(.approvePermission) marks the item resolved")
    func resolvePermission() async throws {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(.permission("s1", requestId: "r1"))
        let itemId = store.items[0].id
        try await store.send(.approvePermission(itemId: itemId, mode: .once))
        #expect(store.pending.isEmpty)
        if case .resolved(let decision, _) = store.items[0].status {
            #expect(decision == .permission(.once))
        } else {
            Issue.record("expected .resolved status")
        }
    }

    @Test("Resolved elicitation history redacts secret answers")
    func resolvedSecretAnswerIsRedacted() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "s-secret",
            hookEventName: .askUserQuestion,
            source: "codex",
            toolInputJSON: #"{"fields":[{"id":"name","prompt":"Name","input_type":"text"},{"id":"token","prompt":"Token","input_type":"secret"}]}"#,
            requestId: "r-secret"
        ))
        let itemID = store.items[0].id

        store.markResolved(
            itemID,
            decision: .question(selections: ["name=cmux", "token=top-secret"])
        )

        guard case .resolved(.question(let selections), _) = store.items[0].status else {
            Issue.record("expected resolved question")
            return
        }
        #expect(selections == ["name=cmux", "token=<provided>"])
    }

    @Test("Appending a completed-turn reply creates authoritative user activity")
    func appendCompletedTurnReply() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "s-reply",
            hookEventName: .stop,
            source: "claude",
            toolInputJSON: #"{"reason":"waiting"}"#
        ))
        let stopID = store.items[0].id

        #expect(store.appendUserReply(to: stopID, text: "Continue with tests"))
        #expect(store.items.count == 2)
        #expect(store.items.last?.kind == .userPrompt)
        if case .userPrompt(let text) = store.items.last?.payload {
            #expect(text == "Continue with tests")
        } else {
            Issue.record("expected synthetic user prompt")
        }
        #expect(!store.appendUserReply(to: stopID, text: "Duplicate"))
    }

    @Test("Unknown major lifecycle events remain chronological telemetry")
    func unknownLifecycleTelemetry() throws {
        let store = WorkstreamStore(ringCapacity: 10)
        let eventData = Data(#"{"session_id":"s-future","hook_event_name":"TaskCompleted","_source":"codex","tool_name":"apply_patch","tool_input":{"ok":true}}"#.utf8)
        let event = try JSONDecoder().decode(WorkstreamEvent.self, from: eventData)
        store.ingest(event)
        #expect(store.items.count == 1)
        #expect(store.items[0].kind == .toolResult)
        if case .toolResult(let toolName, _, _) = store.items[0].payload {
            #expect(toolName == "apply_patch")
        } else {
            Issue.record("expected tool result telemetry")
        }
    }

    @Test("Ring buffer evicts oldest items past capacity")
    func ringEviction() {
        let store = WorkstreamStore(ringCapacity: 3)
        for i in 0..<5 {
            store.ingest(.permission("s\(i)", requestId: "r\(i)"))
        }
        #expect(store.items.count == 3)
        #expect(store.items.first?.workstreamId == "s2")
        #expect(store.items.last?.workstreamId == "s4")
    }

    @Test("start loads a small recent slice and pages older persisted rows on demand")
    func lazyLoadPersistedHistory() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-store-page-\(UUID().uuidString).jsonl")
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

        let store = WorkstreamStore(
            persistence: persistence,
            ringCapacity: 10,
            initialLoadLimit: 2,
            historyPageSize: 2
        )
        await store.start()
        #expect(store.items.map(\.workstreamId) == ["s3", "s4"])
        #expect(store.items.allSatisfy { !$0.status.isPending })
        #expect(store.hasMorePersistedItems)

        await store.loadOlderItems()
        #expect(store.items.map(\.workstreamId) == ["s1", "s2", "s3", "s4"])
        #expect(store.hasMorePersistedItems)

        await store.loadOlderItems()
        #expect(store.items.map(\.workstreamId) == ["s0", "s1", "s2", "s3", "s4"])
        #expect(!store.hasMorePersistedItems)
    }

    @Test("restored pending items stay expired across older and mobile history pages")
    func restoredPendingHistoryExpires() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-restored-pending-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        for index in 0..<5 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "session-\(index)",
                source: .claude,
                kind: .permissionRequest,
                payload: .permissionRequest(
                    requestId: "request-\(index)",
                    toolName: "Bash",
                    toolInputJSON: "{}",
                    pattern: nil
                )
            ))
        }

        let store = WorkstreamStore(
            persistence: persistence,
            ringCapacity: 10,
            initialLoadLimit: 2,
            historyPageSize: 2
        )
        await store.start()
        await store.loadOlderItems()
        let mobilePage = try await store.historyPage(endingBefore: nil, limit: 5)

        #expect(store.items.allSatisfy { !$0.status.isPending })
        #expect(mobilePage.items.allSatisfy { !$0.status.isPending })
    }

    @Test("mobile history pages persisted rows by stable item cursor")
    func mobilePersistedHistoryPages() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-mobile-page-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        var ids: [UUID] = []
        for index in 0..<650 {
            let id = UUID()
            ids.append(id)
            try await persistence.append(WorkstreamItem(
                id: id,
                workstreamId: "session-\(index)",
                source: .codex,
                kind: .assistantMessage,
                workspaceId: "workspace-\(index)",
                surfaceId: "surface-\(index)",
                payload: .assistantMessage(text: "event \(index)")
            ))
        }
        let store = WorkstreamStore(persistence: persistence, ringCapacity: 2_000)
        let readsBefore = await persistence.loadPageCallCount

        let first = try await store.historyPage(endingBefore: nil, limit: 300)
        let second = try await store.historyPage(endingBefore: first.nextCursor, limit: 300)
        let third = try await store.historyPage(endingBefore: second.nextCursor, limit: 300)

        #expect(first.items.map(\.id) == Array(ids[350..<650]))
        #expect(second.items.map(\.id) == Array(ids[50..<350]))
        #expect(third.items.map(\.id) == Array(ids[0..<50]))
        #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
        #expect(Set(second.items.map(\.id)).isDisjoint(with: third.items.map(\.id)))
        #expect(first.hasMore && second.hasMore && !third.hasMore)
        #expect(first.items.first?.workspaceId == "workspace-350")
        #expect(first.items.first?.surfaceId == "surface-350")
        let readsAfter = await persistence.loadPageCallCount
        #expect(readsAfter - readsBefore == 3)
    }

    @Test("mobile persisted history rejects a cursor whose offset names another row")
    func mobilePersistedHistoryRejectsTamperedOffset() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-mobile-cursor-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        for index in 0..<4 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "session-\(index)",
                source: .codex,
                kind: .assistantMessage,
                payload: .assistantMessage(text: "event \(index)")
            ))
        }
        let store = WorkstreamStore(persistence: persistence, ringCapacity: 10)
        let first = try await store.historyPage(endingBefore: nil, limit: 2)
        let cursor = try #require(first.nextCursor)
        let data = try #require(Data(base64Encoded: cursor))
        let raw = try #require(String(data: data, encoding: .utf8))
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        let tampered = Data("p1:0:\(parts[2])".utf8).base64EncodedString()

        await #expect(throws: WorkstreamHistoryError.invalidCursor) {
            try await store.historyPage(endingBefore: tampered, limit: 2)
        }
    }

    @Test("mobile first page includes newly ingested rows")
    func mobileHistoryIncludesLiveTail() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-mobile-live-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "persisted",
            source: .codex,
            kind: .assistantMessage,
            payload: .assistantMessage(text: "persisted")
        ))
        let store = WorkstreamStore(persistence: persistence, ringCapacity: 10)
        await store.start()
        store.ingest(WorkstreamEvent(
            sessionId: "live",
            hookEventName: .notification,
            source: "codex"
        ))

        let page = try await store.historyPage(endingBefore: nil, limit: 10)

        #expect(page.items.map(\.workstreamId) == ["persisted", "live"])
    }

    @Test("mobile history drains one ordered persistence writer before paging a burst")
    func mobileHistoryDrainsBoundedPersistenceBurst() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-mobile-burst-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let gate = PersistenceAppendGate()
        let persistence = WorkstreamPersistence(fileURL: tmp, beforeAppend: { await gate.wait() })
        let store = WorkstreamStore(persistence: persistence, ringCapacity: 1_000)
        for index in 0..<650 {
            store.ingest(WorkstreamEvent(
                sessionId: "burst-\(index)",
                hookEventName: .notification,
                source: "codex"
            ))
        }
        let acceptedIDs = store.items.map(\.id)
        #expect(store.activePersistenceDrainCount == 1)

        let firstTask = Task { try await store.historyPage(endingBefore: nil, limit: 300) }
        await gate.release()
        let first = try await firstTask.value
        let second = try await store.historyPage(endingBefore: first.nextCursor, limit: 300)
        let third = try await store.historyPage(endingBefore: second.nextCursor, limit: 300)

        #expect(first.items.map(\.id) == Array(acceptedIDs[350..<650]))
        #expect(second.items.map(\.id) == Array(acceptedIDs[50..<350]))
        #expect(third.items.map(\.id) == Array(acceptedIDs[0..<50]))
        #expect(first.hasMore && second.hasMore && !third.hasMore)
        #expect(store.activePersistenceDrainCount == 0)
    }

    @Test("mobile in-memory history rejects a cursor invalidated by ring eviction")
    func mobileInMemoryHistoryRejectsEvictedCursor() async throws {
        let store = WorkstreamStore(ringCapacity: 4)
        for index in 0..<4 {
            store.ingest(WorkstreamEvent(
                sessionId: "session-\(index)",
                hookEventName: .notification,
                source: "codex"
            ))
        }
        let first = try await store.historyPage(endingBefore: nil, limit: 2)
        let cursor = try #require(first.nextCursor)
        store.ingest(WorkstreamEvent(
            sessionId: "session-4",
            hookEventName: .notification,
            source: "codex"
        ))

        await #expect(throws: WorkstreamHistoryError.invalidCursor) {
            try await store.historyPage(endingBefore: cursor, limit: 2)
        }
    }

    @Test("expireAbandonedItems expires items whose agent PID is dead")
    func expireAbandoned() {
        let clock = TestClock(initial: Date(timeIntervalSince1970: 0))
        let store = WorkstreamStore(ringCapacity: 10, clock: { clock.now })
        // Alive agent (pid=1000), dead agent (pid=2000).
        store.ingest(.permission("alive", requestId: "r1", at: clock.now, ppid: 1000))
        store.ingest(.permission("dead", requestId: "r2", at: clock.now, ppid: 2000))
        store.ingest(.permission("untracked", requestId: "r3", at: clock.now))
        // Injected liveness: only 1000 is alive.
        store.expireAbandonedItems { pid in pid == 1000 }
        #expect(store.items.count == 3)
        #expect(store.items[0].status.isPending)
        if case .expired = store.items[1].status {} else {
            Issue.record("dead-pid item should be expired")
        }
        // Item with no ppid: no change (we don't know liveness).
        #expect(store.items[2].status.isPending)
    }

    @Test("expirePending moves stale pending items to expired")
    func expirePending() {
        let clock = TestClock(initial: Date(timeIntervalSince1970: 0))
        let store = WorkstreamStore(ringCapacity: 10, clock: { clock.now })
        store.ingest(.permission("s1", requestId: "r1", at: clock.now))
        clock.advance(200)
        store.expirePending(olderThan: 60)
        if case .expired = store.items[0].status {
            // ok
        } else {
            Issue.record("expected .expired status after timeout")
        }
    }

    @Test("Telemetry items (toolUse) never enter pending")
    func telemetryNeverPending() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .preToolUse,
            source: "claude",
            toolName: "Read"
        ))
        #expect(store.items.count == 1)
        #expect(store.pending.isEmpty)
        #expect(store.items[0].kind == .toolUse)
    }

    @Test("PostToolUse preserves failure status from the wire event")
    func postToolUsePreservesFailureStatus() throws {
        let data = try #require(
            """
            {
              "session_id": "pi-session",
              "hook_event_name": "PostToolUse",
              "_source": "pi",
              "tool_name": "bash",
              "tool_input": {"kind": "object", "key_count": 2},
              "is_error": true
            }
            """.data(using: .utf8)
        )
        let event = try JSONDecoder().decode(WorkstreamEvent.self, from: data)
        let encoded = try JSONEncoder().encode(event)
        let encodedObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(encodedObject["is_error"] as? Bool == true)
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(event)

        let item = try #require(store.items.first)
        if case .toolResult(let toolName, _, let isError) = item.payload {
            #expect(toolName == "bash")
            #expect(isError)
        } else {
            Issue.record("expected PostToolUse to decode as toolResult telemetry")
        }
    }

    @Test("Codex CLI lifecycle feed events stay telemetry")
    func codexLifecycleFeedEventsStayTelemetry() {
        let store = WorkstreamStore(
            ringCapacity: 10,
            titleProvider: { event in
                switch event.hookEventName {
                case .preCompact, .postCompact:
                    return "Compaction"
                case .subagentStart, .subagentStop:
                    return "Subagent"
                default:
                    return nil
                }
            }
        )
        let events: [WorkstreamEvent.HookEventName] = [
            .postToolUse,
            .preCompact,
            .postCompact,
            .subagentStart,
            .subagentStop,
        ]

        for event in events {
            store.ingest(WorkstreamEvent(
                sessionId: "codex-session",
                hookEventName: event,
                source: "codex"
            ))
        }

        #expect(store.items.count == events.count)
        #expect(store.pending.isEmpty)
        #expect(store.items.allSatisfy { $0.status == .telemetry })
        #expect(store.items.map(\.title).contains("Compaction"))
        #expect(store.items.map(\.title).contains("Subagent"))
        #expect(!store.items.map(\.title).contains("PreCompact"))
        #expect(!store.items.map(\.title).contains("PostCompact"))
        #expect(!store.items.map(\.title).contains("SubagentStart"))
        #expect(!store.items.contains { $0.kind == .sessionStart })
        #expect(!store.items.contains { $0.kind == .stop })
        if let compactionStartItem = store.items.first(where: {
            $0.title == "Compaction" && $0.kind == .toolUse
        }) {
            if case .toolUse(let toolName, _) = compactionStartItem.payload {
                #expect(toolName == "Compaction")
            } else {
                Issue.record("expected PreCompact to decode as toolUse telemetry")
            }
        } else {
            Issue.record("expected PreCompact item")
        }
        if let subagentStartItem = store.items.first(where: {
            $0.title == "Subagent" && $0.kind == .toolUse
        }) {
            #expect(subagentStartItem.kind == .toolUse)
            if case .toolUse(let toolName, _) = subagentStartItem.payload {
                #expect(toolName == "Subagent")
            } else {
                Issue.record("expected SubagentStart to decode as toolUse telemetry")
            }
        } else {
            Issue.record("expected SubagentStart item")
        }
        if let subagentStopItem = store.items.first(where: {
            $0.title == "Subagent" && $0.kind == .toolResult
        }) {
            #expect(subagentStopItem.kind == .toolResult)
            if case .toolResult(let toolName, _, _) = subagentStopItem.payload {
                #expect(toolName == "Subagent")
            } else {
                Issue.record("expected SubagentStop to decode as toolResult telemetry")
            }
        } else {
            Issue.record("expected SubagentStop item")
        }
    }

    @Test("Telemetry payloads preserve prompt, stop, and todo content")
    func telemetryContent() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .userPromptSubmit,
            source: "claude",
            toolInputJSON: #"{"prompt":"ship it"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .stop,
            source: "claude",
            toolInputJSON: #"{"reason":"done"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .todoWrite,
            source: "claude",
            toolInputJSON: #"{"todos":[{"id":"t1","content":"test","status":"in_progress"}]}"#
        ))

        if case .userPrompt(let text) = store.items[0].payload {
            #expect(text == "ship it")
        } else {
            Issue.record("expected user prompt payload")
        }
        if case .stop(let reason) = store.items[1].payload {
            #expect(reason == "done")
        } else {
            Issue.record("expected stop payload")
        }
        if case .todos(let todos) = store.items[2].payload {
            #expect(todos.first?.content == "test")
            #expect(todos.first?.state == .inProgress)
        } else {
            Issue.record("expected todos payload")
        }
    }

    @Test("Prompt context carries into later permission requests")
    func promptContextCarriesIntoPermission() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .userPromptSubmit,
            source: "claude",
            toolInputJSON: #"{"prompt":"demo the permission UI"}"#,
            context: WorkstreamContext(permissionMode: "plan")
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .permissionRequest,
            source: "claude",
            toolName: "Bash",
            toolInputJSON: #"{"command":"echo hi"}"#,
            requestId: "r1"
        ))

        #expect(store.items[1].context?.lastUserMessage == "demo the permission UI")
        #expect(store.items[1].context?.permissionMode == "plan")
    }

    @Test("Exit plan context parses plan JSON")
    func exitPlanParsesContext() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .exitPlanMode,
            source: "claude",
            toolName: "ExitPlanMode",
            toolInputJSON: #"""
            {
              "plan": "# Demo Plan\n\n## Context\nShow the new feed UI.",
              "allowedPrompts": [
                {"tool": "Bash", "prompt": "run reload.sh --tag feedctx"}
              ],
              "planFilePath": "/tmp/demo.md"
            }
            """#,
            context: WorkstreamContext(lastUserMessage: "make a plan"),
            requestId: "plan-1"
        ))

        let item = store.items[0]
        #expect(item.context?.lastUserMessage == "make a plan")
        #expect(item.context?.planSummary == "Show the new feed UI.")
        #expect(item.context?.allowedPrompts.first?.tool == "Bash")
        #expect(item.context?.allowedPrompts.first?.prompt == "run reload.sh --tag feedctx")
    }
}

private actor PersistenceAppendGate {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

/// Mutable clock wrapper safe to capture by a `@Sendable` closure in tests.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(initial: Date) { _now = initial }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return _now
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _now = _now.addingTimeInterval(seconds)
    }
}

private extension WorkstreamEvent {
    static func permission(
        _ sessionId: String,
        requestId: String,
        at date: Date = Date(),
        ppid: Int? = nil
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: sessionId,
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Write",
            toolInputJSON: "{}",
            requestId: requestId,
            ppid: ppid,
            receivedAt: date
        )
    }
}
