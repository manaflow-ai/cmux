import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextAgentPane

@Suite @MainActor
struct QueuedEditDraftTests {
    private func draft(_ revision: String, text: String = "unfinished edit") -> JSONValue {
        .object(["revision": .string(revision), "originalPrompt": .string("queued original"),
                 "originalImages": .array([.string("image-a"), .string("image-b")]),
                 "text": .string(text), "droppedImages": .array([.string("image-a")])])
    }

    @Test func nextBuildReadsTextAndAttachmentReferencesFromStableDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let buildA = AgentPaneQueuedEdits(directory: directory)
        try await buildA.set(session: "session-a", prompt: "queue-a", value: draft("typed"))
        let buildB = AgentPaneQueuedEdits(directory: directory)
        #expect(try await buildB.read(session: "session-a") == .object(["queue-a": draft("typed")]))
        #expect(try await buildB.read(session: "session-b") == .object([:]))
        try await buildB.clear(session: "session-a", prompt: "queue-a", revision: "typed")
        #expect(try await AgentPaneQueuedEdits(directory: directory).read(session: "session-a") == .object([:]))
    }

    @Test func olderAcknowledgementCannotClearNewerTyping() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentPaneQueuedEdits(directory: directory)
        try await store.set(session: "session", prompt: "queue", value: draft("rpc-in-flight"))
        try await store.set(session: "session", prompt: "queue", value: draft("newer", text: "typed meanwhile"))
        try await store.clear(session: "session", prompt: "queue", revision: "rpc-in-flight")
        #expect(try await store.read(session: "session") == .object(["queue": draft("newer", text: "typed meanwhile")]))
    }
}
