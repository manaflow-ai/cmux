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
    }
}
