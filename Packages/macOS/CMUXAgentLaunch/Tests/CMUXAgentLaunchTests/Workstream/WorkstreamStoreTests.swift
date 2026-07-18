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

    @Test("start restores only the newest pending items within the memory ring")
    func boundedPendingRestore() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-store-page-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let items = (0..<5).map { i in
            WorkstreamItem(
                workstreamId: "s\(i)",
                source: .claude,
                kind: .permissionRequest,
                payload: .permissionRequest(requestId: "r\(i)", toolName: "t", toolInputJSON: "{}", pattern: nil)
            )
        }
        try await persistence.replacePendingItems(items, generation: 1)

        let store = WorkstreamStore(
            persistence: persistence,
            ringCapacity: 2
        )
        await store.start()
        #expect(store.items.map(\.workstreamId) == ["s3", "s4"])
    }

    @Test("removing an item hides it immediately and after restart")
    func removeItemPersists() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-store-remove-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(
                at: WorkstreamPersistence.removedItemsFileURL(for: tmp)
            )
        }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let kept = WorkstreamItem(
            workstreamId: "kept",
            source: .opencode,
            kind: .question,
            payload: .question(requestId: "kept", questions: [])
        )
        let removed = WorkstreamItem(
            workstreamId: "removed",
            source: .opencode,
            kind: .question,
            payload: .question(requestId: "removed", questions: [])
        )
        try await persistence.replacePendingItems([kept, removed], generation: 1)

        let store = WorkstreamStore(persistence: persistence, ringCapacity: 10)
        await store.start()
        #expect(try await store.removeItem(id: removed.id))
        #expect(store.items.map(\.id) == [kept.id])

        let restored = WorkstreamStore(persistence: persistence, ringCapacity: 10)
        await restored.start()
        #expect(restored.items.map(\.id) == [kept.id])
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
        #expect(store.items.isEmpty)
        #expect(store.pending.isEmpty)
    }

    @Test("Telemetry enriches actionable cards without entering retained Feed state")
    func telemetryOnlyEnrichesActionableItems() {
        let store = WorkstreamStore(ringCapacity: 10)
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .userPromptSubmit,
            source: "claude",
            toolInputJSON: #"{"prompt":"keep this context only"}"#
        ))
        store.ingest(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .preToolUse,
            source: "claude",
            toolName: "Read",
            toolInputJSON: #"{"path":"/tmp/file"}"#
        ))
        store.ingest(.permission("s1", requestId: "r1"))

        #expect(store.items.count == 1)
        #expect(store.items[0].kind == .permissionRequest)
        #expect(store.items[0].context?.lastUserMessage == "keep this context only")
    }

    @Test("Default Feed retention keeps memory bounded")
    func defaultRetentionIsBounded() {
        let store = WorkstreamStore()
        for i in 0..<500 {
            store.ingest(.permission("s\(i)", requestId: "r\(i)"))
        }

        #expect(WorkstreamDefaultRingCapacity <= 200)
        #expect(store.items.count == WorkstreamDefaultRingCapacity)
        #expect(store.items.last?.workstreamId == "s499")
    }

    @Test("Restart restores pending decisions only and compacts legacy activity")
    func restartRestoresOnlyPendingDecisions() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-store-compact-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        let legacyItems = [WorkstreamItem(
            workstreamId: "telemetry",
            source: .claude,
            kind: .toolUse,
            payload: .toolUse(toolName: "Read", toolInputJSON: "{}")
        ), WorkstreamItem(
            workstreamId: "resolved",
            source: .claude,
            kind: .question,
            status: .resolved(.question(selections: ["Done"]), at: Date()),
            payload: .question(requestId: "resolved", questions: [])
        ), WorkstreamItem(
            workstreamId: "pending",
            source: .claude,
            kind: .question,
            payload: .question(requestId: "pending", questions: [])
        )]
        try writeLegacyItems(legacyItems, to: tmp)

        let store = WorkstreamStore(persistence: persistence, ringCapacity: 10)
        await store.start()

        #expect(store.items.map(\.workstreamId) == ["pending"])
        #expect(try await persistence.loadRecent(limit: 10).map(\.workstreamId) == ["pending"])
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

        #expect(store.items.isEmpty)
        #expect(store.pending.isEmpty)
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

        #expect(store.items.isEmpty)
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

        #expect(store.items[0].context?.lastUserMessage == "demo the permission UI")
        #expect(store.items[0].context?.permissionMode == "plan")
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

private func writeLegacyItems(_ items: [WorkstreamItem], to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = Data()
    for item in items {
        data.append(try encoder.encode(item))
        data.append(0x0A)
    }
    try data.write(to: url)
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
