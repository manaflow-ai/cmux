import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Workstream revision coordination")
struct WorkstreamRevisionConcurrencyTests {
    @Test("Independent persistence owners cannot lower a committed high-water mark")
    func concurrentWritersPreserveMaximum() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("workstream.jsonl")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<16 {
                group.addTask {
                    let persistence = WorkstreamPersistence(fileURL: url)
                    for value in 1...32 { try await persistence.recordRevision(writer * 1000 + value) }
                }
            }
            try await group.waitForAll()
        }
        let restarted = WorkstreamPersistence(fileURL: url)
        #expect(try await restarted.loadRevision() == 15_032)
        try await restarted.clear()
        #expect(try await WorkstreamPersistence(fileURL: url).loadRevision() == 15_032)
    }
}
