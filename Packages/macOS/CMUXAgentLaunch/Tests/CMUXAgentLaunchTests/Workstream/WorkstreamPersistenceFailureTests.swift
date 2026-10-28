import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Workstream persistence failures")
@MainActor
struct WorkstreamPersistenceFailureTests {
    @Test("A failed revision write remains observable after draining")
    func revisionFailureSurvivesDrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.jsonl")
        try FileManager.default.createDirectory(at: url.appendingPathExtension("revision"), withIntermediateDirectories: false)
        let store = WorkstreamStore(persistence: WorkstreamPersistence(fileURL: url))
        await store.start()
        await store.flushPersistence()
        #expect(!store.hasPendingPersistenceWrites)
        #expect(store.lastPersistenceError != nil)
        #expect(await store.flushPersistence() == false)
    }

    @Test("A failed append remains observable after draining")
    func appendFailureSurvivesDrain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.jsonl")
        let store = WorkstreamStore(persistence: WorkstreamPersistence(fileURL: url))
        await store.start()
        await store.flushPersistence()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        store.ingest(WorkstreamEvent(sessionId: "live", hookEventName: .sessionStart, source: "claude", cwd: "/tmp"))
        await store.flushPersistence()
        #expect(!store.hasPendingPersistenceWrites)
        #expect(store.lastPersistenceError != nil)
        #expect(await store.flushPersistence() == false)
    }

    @Test("Draining includes writes queued while the earlier sidecar write is suspended")
    func drainIncludesNewWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.jsonl")
        let gate = WorkstreamClearGate()
        let persistence = WorkstreamPersistence(fileURL: url, fileManager: WorkstreamClearFileManager(gate: gate))
        let store = WorkstreamStore(persistence: persistence)
        await store.start()
        func ingest(_ session: String) {
            store.ingest(WorkstreamEvent(sessionId: session, hookEventName: .sessionStart, source: "claude"))
        }
        ingest("warm")
        await store.flushPersistence()
        gate.arm(count: 2)
        ingest("first")
        var entries = gate.entries.makeAsyncIterator()
        _ = await entries.next()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let flush = Task { @MainActor in
            continuation.yield(())
            await store.flushPersistence()
            return store.hasPendingPersistenceWrites
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        ingest("during-flush")
        gate.release()
        _ = await entries.next()
        // Let any continuation of the first write run while the second write
        // remains blocked at a real filesystem boundary.
        await Task.yield()
        gate.release()
        #expect(await flush.value == false)
        #expect(try await persistence.loadRecent(limit: 10).map(\.workstreamId) == ["warm", "first", "during-flush"])
    }

}
