import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Workstream clear ordering")
struct WorkstreamClearOrderingTests {
    @Test("An append waits until clear has saved the floor and removed the old journal")
    func appendDuringClearSurvives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.jsonl")
        let manager = WorkstreamClearFileManager()
        let persistence = WorkstreamPersistence(fileURL: url, fileManager: manager)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let old = WorkstreamItem(workstreamId: "old", source: .claude, kind: .sessionStart,
                                 createdAt: date, payload: .sessionStart)
        let new = WorkstreamItem(workstreamId: "new", source: .claude, kind: .sessionStart,
                                 createdAt: date, payload: .sessionStart)
        try await persistence.append(old)
        manager.arm()
        let clear = Task { try await persistence.clear() }
        var entries = manager.entries.makeAsyncIterator()
        _ = await entries.next()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let append = Task {
            try await persistence.appendForOrderingTest(new) { continuation.yield(()) }
        }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        // This actor read runs after append has entered. Until clear's durable
        // floor is saved, that append must not mutate the journal being removed.
        let duringClear = try await persistence.loadRecent(limit: 10)
        manager.release()
        try await clear.value
        try await append.value
        #expect(duringClear == [old])
        #expect(try await persistence.loadRecent(limit: 10) == [new])
        #expect(try await WorkstreamPersistence(fileURL: url).loadRecent(limit: 10) == [new])
    }
}

private extension WorkstreamPersistence {
    func appendForOrderingTest(_ item: WorkstreamItem, entered: @Sendable () -> Void) async throws {
        entered()
        try await append(item)
    }
}
