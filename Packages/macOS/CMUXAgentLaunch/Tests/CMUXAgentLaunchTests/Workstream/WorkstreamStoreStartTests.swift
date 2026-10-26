import Foundation
import Testing
@testable import CMUXAgentLaunch

@MainActor
@Suite("WorkstreamStore start")
struct WorkstreamStoreStartTests {
    @Test("Startup retains a durable revision floor above the JSONL byte count")
    func startupRetainsDurableRevisionFloor() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-start-revision-floor-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("revision"))
        }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.recordRevision(1_000_000)
        try await persistence.append(WorkstreamItem(
            workstreamId: "small-row",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        let store = WorkstreamStore(persistence: WorkstreamPersistence(fileURL: tmp))
        await store.start()

        #expect(store.revision >= 1_000_000)
    }

    @Test("Missing or hard-budget startup retains a durable revision floor")
    func startupRetainsFloorWhenHistoryIsUnavailable() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-start-missing-floor-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: missingURL)
            try? FileManager.default.removeItem(at: missingURL.appendingPathExtension("revision"))
        }
        let missingPersistence = WorkstreamPersistence(fileURL: missingURL)
        try await missingPersistence.recordRevision(2_000)
        let missingStore = WorkstreamStore(
            persistence: WorkstreamPersistence(fileURL: missingURL)
        )
        await missingStore.start()
        #expect(missingStore.revision >= 2_000)

        let cutoffURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-start-cutoff-floor-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: cutoffURL)
            try? FileManager.default.removeItem(at: cutoffURL.appendingPathExtension("revision"))
        }
        let cutoffPersistence = WorkstreamPersistence(fileURL: cutoffURL)
        try await cutoffPersistence.recordRevision(3_000)
        try await cutoffPersistence.append(WorkstreamItem(
            workstreamId: "cutoff-row",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))
        let cutoffStore = WorkstreamStore(
            persistence: WorkstreamPersistence(fileURL: cutoffURL),
            startupHardBudgetNanoseconds: 0
        )
        await cutoffStore.start()
        #expect(cutoffStore.revision >= 3_000)
    }

    @Test("Repeated and concurrent starts load history and subscribe once (#21352)")
    func repeatedStartsShareOnePass() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-start-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "persisted",
            source: .claude,
            kind: .permissionRequest,
            payload: .permissionRequest(requestId: "r0", toolName: "t", toolInputJSON: "{}", pattern: nil)
        ))
        let transport = CountingWorkstreamTransport()
        let store = WorkstreamStore(
            transport: transport,
            persistence: persistence,
            ringCapacity: 10
        )

        async let first: Void = store.start()
        async let second: Void = store.start()
        _ = await (first, second)
        #expect(store.items.map(\.workstreamId) == ["persisted"])

        store.ingest(WorkstreamEvent(
            sessionId: "live",
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Write",
            toolInputJSON: "{}",
            requestId: "r1"
        ))
        let revisionBeforeRestart = store.revision

        await store.start()

        #expect(await transport.subscribeCount == 1)
        #expect(store.items.map(\.workstreamId) == ["persisted", "live"])
        #expect(store.revision == revisionBeforeRestart)
    }

    @Test("Startup keeps bounded persistence diagnostics observable")
    func startupPublishesPersistenceDiagnostics() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-start-diagnostics-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "persisted",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        let store = WorkstreamStore(
            persistence: persistence,
            ringCapacity: 10,
            startupBudgetNanoseconds: 0
        )
        await store.start()

        #expect(store.items.map(\.workstreamId) == ["persisted"])
        #expect(store.lastPersistenceError == nil)
        #expect(store.lastPersistenceDiagnostic?.fileBytes ?? 0 > 0)
        #expect(store.lastPersistenceDiagnostic?.exceededBudget == true)
        #expect(store.lastPersistenceDiagnostic?.missingFile == false)
    }

    @Test("startup hard cutoff retains the latest-row cursor for paging")
    func startupHardCutoffRetainsCursor() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-start-hard-cutoff-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "persisted",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        let store = WorkstreamStore(
            persistence: persistence,
            ringCapacity: 10,
            startupHardBudgetNanoseconds: 0
        )
        await store.start()

        #expect(store.items.isEmpty)
        #expect(store.hasMorePersistedItems == true)
        #expect(store.lastPersistenceDiagnostic?.exceededBudget == true)
    }

    @Test("Startup exposes persistence failures instead of treating them as empty history")
    func startupPublishesPersistenceError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-start-error-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        let store = WorkstreamStore(
            persistence: WorkstreamPersistence(fileURL: directory),
            ringCapacity: 10
        )
        await store.start()

        #expect(store.items.isEmpty)
        #expect(store.lastPersistenceDiagnostic == nil)
        #expect(store.lastPersistenceError != nil)
    }

    @Test("startup persistence failure invalidates remote mirrors")
    func startupPersistenceFailureNotifiesRevisionChange() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-start-error-hook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        let store = WorkstreamStore(
            persistence: WorkstreamPersistence(fileURL: directory),
            ringCapacity: 10
        )
        var revisions: [Int] = []
        store.onRevisionChange = { revisions.append($0) }

        await store.start()

        #expect(store.lastPersistenceError != nil)
        #expect(revisions.count == 1)
        #expect(revisions.first == store.revision)
    }

    @Test("Paging advances past a malformed page to recover older history")
    func pagingSkipsMalformedPage() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-start-malformed-page-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "old",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        let writer = try FileHandle(forWritingTo: tmp)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data("not-json-1\nnot-json-2\n".utf8))
        try writer.close()

        try await persistence.append(WorkstreamItem(
            workstreamId: "new",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        let store = WorkstreamStore(
            persistence: persistence,
            ringCapacity: 10,
            initialLoadLimit: 1,
            historyPageSize: 2
        )
        await store.start()
        #expect(store.items.map(\.workstreamId) == ["new"])
        #expect(store.hasMorePersistedItems)

        await store.loadOlderItems()

        #expect(store.items.map(\.workstreamId) == ["old", "new"])
        #expect(!store.hasMorePersistedItems)
    }

    @Test("Paging bounds a duplicate or malformed history walk per request")
    func pagingWalkLimitPreservesCursor() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-start-page-limit-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(WorkstreamItem(
            workstreamId: "old",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))
        let writer = try FileHandle(forWritingTo: tmp)
        try writer.seekToEnd()
        for _ in 0..<12 {
            try writer.write(contentsOf: Data("not-json\n".utf8))
        }
        try writer.close()
        try await persistence.append(WorkstreamItem(
            workstreamId: "new",
            source: .claude,
            kind: .sessionStart,
            payload: .sessionStart
        ))

        let store = WorkstreamStore(
            persistence: persistence,
            ringCapacity: 10,
            initialLoadLimit: 1,
            historyPageSize: 1,
            historyPageWalkLimit: 2
        )
        await store.start()
        await store.loadOlderItems()

        #expect(store.items.map(\.workstreamId) == ["new"])
        #expect(store.hasMorePersistedItems)
    }

    @Test("Startup and older pages reach every row when rows are near the read window")
    func startupThenOlderPagesKeepLargeRows() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-start-large-rows-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("revision"))
        }
        let persistence = WorkstreamPersistence(fileURL: tmp)
        for index in 0..<700 {
            try await persistence.append(WorkstreamItem(
                workstreamId: "row-\(index)",
                source: .claude,
                kind: .toolUse,
                payload: .toolUse(toolName: "Write", toolInputJSON: String(repeating: "x", count: 30_000))
            ))
        }

        let store = WorkstreamStore(persistence: persistence)
        await store.start()
        for _ in 0..<20 where store.hasMorePersistedItems {
            await store.loadOlderItems()
        }

        #expect(store.items.map(\.workstreamId) == (0..<700).map { "row-\($0)" })
        #expect(!store.hasMorePersistedItems)
    }

    @Test("Bounded recovery keeps only the newest mutation for an event")
    func boundedRecoveryDeduplicatesMutations() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-bounded-dedupe-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("revision"))
        }

        let id = UUID()
        let pending = WorkstreamItem(
            id: id,
            workstreamId: "session",
            source: .claude,
            kind: .permissionRequest,
            status: .pending,
            payload: .permissionRequest(
                requestId: "request",
                toolName: "Write",
                toolInputJSON: "{}",
                pattern: nil
            )
        )
        let resolved = WorkstreamItem(
            id: id,
            workstreamId: "session",
            source: .claude,
            kind: .permissionRequest,
            status: .resolved(.permission(.once), at: Date()),
            payload: pending.payload
        )
        let persistence = WorkstreamPersistence(fileURL: tmp)
        try await persistence.append(pending)
        try await persistence.append(resolved)

        let store = WorkstreamStore(
            persistence: WorkstreamPersistence(fileURL: tmp),
            initialLoadLimit: 10,
            startupHardBudgetNanoseconds: 0
        )
        await store.start()
        await store.loadOlderItems()

        #expect(store.items.count == 1)
        #expect(store.items.first?.id == id)
        #expect(store.items.first?.status.isPending == false)
    }

    @Test("The store reports queued journal writes until they land")
    func pendingPersistenceWritesAreObservableUntilFlushed() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workstream-pending-writes-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: tmp.appendingPathExtension("revision"))
        }
        let store = WorkstreamStore(persistence: WorkstreamPersistence(fileURL: tmp))
        await store.start()
        await store.flushPersistence()
        #expect(!store.hasPendingPersistenceWrites)

        // Quit consults this synchronously to decide whether to wait for
        // the Feed before letting AppKit terminate.
        store.ingest(WorkstreamEvent(
            sessionId: "live",
            hookEventName: .permissionRequest,
            source: "claude",
            cwd: "/tmp",
            toolName: "Write",
            toolInputJSON: "{}",
            requestId: "r1"
        ))
        #expect(store.hasPendingPersistenceWrites)

        await store.flushPersistence()
        #expect(!store.hasPendingPersistenceWrites)
    }

}

private actor CountingWorkstreamTransport: WorkstreamTransport {
    private(set) var subscribeCount = 0

    func subscribe(onEvent: @escaping @Sendable (WorkstreamEvent) -> Void) async throws {
        subscribeCount += 1
    }

    func send(_ action: WorkstreamAction) async throws {}
}
