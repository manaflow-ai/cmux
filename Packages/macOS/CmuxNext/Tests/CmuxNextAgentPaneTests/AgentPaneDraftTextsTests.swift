import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor
struct AgentPaneDraftTextsTests {
    @Test func reopeningKeepsSeparateSessionsAndIntentionalClear() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "draft-texts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let work = BackgroundWork()
        let store = AgentPaneDraftTexts(directory: root, work: work)
        try await store.set("first", for: "one")
        try await store.set("second", for: "two")
        try await store.set("", for: "one")

        let reopened = AgentPaneDraftTexts(directory: root, work: work)
        #expect(try await reopened.get("one") == "")
        #expect(try await reopened.get("two") == "second")
        #expect(try await reopened.get("missing") == nil)
    }

    @Test func concurrentSessionWritesDoNotDropEachOthersDrafts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "draft-texts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPaneDraftTexts(directory: root, work: BackgroundWork())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask { try await store.set("text-\(index)", for: "session-\(index)") }
            }
            try await group.waitForAll()
        }
        for index in 0..<12 { #expect(try await store.get("session-\(index)") == "text-\(index)") }
    }

    @Test func malformedExistingFileFailsWithoutClobberingIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "draft-texts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let work = BackgroundWork(), file = root.appending(path: AgentPaneDraftTexts.fileName)
        try await work.run(.userVisible, mayBlock: .files) {
            try FileManager.checked.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("keep unreadable original".utf8).blockingWrite(to: file)
        }
        let store = AgentPaneDraftTexts(directory: root, work: work)
        await #expect(throws: (any Error).self) { try await store.set("new", for: "session") }
        let unchanged = try await work.run(.userVisible, mayBlock: .files) {
            try String(blockingContentsOf: file, encoding: .utf8)
        }
        #expect(unchanged == "keep unreadable original")
    }
}
