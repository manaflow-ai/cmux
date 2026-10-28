import CmuxNextCompat
import CmuxNextWakeups
import Foundation
import Dispatch
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

    @Test func committedQuitFinalizesPendingTextAndRejectsLaterPageWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "draft-texts-finalize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentPaneDraftTexts(directory: root, work: BackgroundWork())
        try await store.set("before quit", for: "session")
        await store.finalizeForQuit()
        try await store.set("after quit", for: "session")
        #expect(try await store.get("session") == "before quit")
    }

    @Test(arguments: ["last draft", ""])
    func finalizationWaitsForBlockedWrites(text: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "draft-texts-blocked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let queued = AsyncStream.makeStream(of: Void.self)
        let work = BackgroundWork(onQueued: { _, _ in queued.continuation.yield(()) })
        let release = DispatchSemaphore(value: 0)
        work.post(.userVisible, mayBlock: .files) { release.wait() }
        defer { release.signal(); queued.continuation.finish() }
        let store = AgentPaneDraftTexts(directory: root, work: work)
        let write = Task { try await store.set(text, for: "session") }
        var iterator = queued.stream.makeAsyncIterator()
        await iterator.next()
        var finished = false
        let started = AsyncStream.makeStream(of: Void.self)
        let quit = Task {
            started.continuation.yield(())
            await store.finalizeForQuit()
            finished = true
        }
        var starting = started.stream.makeAsyncIterator()
        await starting.next()
        #expect(!finished)
        let late = Task { try await store.set("late page callback", for: "session") }
        release.signal()
        try await write.value
        try await late.value
        await quit.value
        #expect(try await store.get("session") == text)
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
