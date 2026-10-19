import Foundation
import Testing
@testable import CMUXAgentLaunch

@MainActor
@Suite("WorkstreamStore start")
struct WorkstreamStoreStartTests {
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
}

private actor CountingWorkstreamTransport: WorkstreamTransport {
    private(set) var subscribeCount = 0

    func subscribe(onEvent: @escaping @Sendable (WorkstreamEvent) -> Void) async throws {
        subscribeCount += 1
    }

    func send(_ action: WorkstreamAction) async throws {}
}
