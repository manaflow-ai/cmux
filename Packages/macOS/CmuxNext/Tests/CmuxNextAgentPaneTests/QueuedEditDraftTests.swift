@testable import CmuxNextCompat
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

    @Test func clearClaimsArtifactBeforeLegacyRetryAndKeepsNormalEmptyRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let legacy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: legacy)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let queueFile = directory.appending(path: AgentPaneQueuedEdits.fileName)
        let current = JSONValue.object(["session-a": .object(["queue-a": draft("owned")])])
        try Data(current.compactText.utf8).write(to: queueFile)
        let ownership = directory.appending(path: ".adopted-v1-\(AgentPaneQueuedEdits.fileName)")
        let legacyFile = legacy.appending(path: AgentPaneQueuedEdits.fileName)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let old = ["session-a": ["queue-a": [
            "revision": "legacy", "originalPrompt": "queued original", "originalImages": ["image-a", "image-b"],
            "text": "stale legacy edit", "droppedImages": ["image-a"],
        ]]] as [String: Any]
        try JSONSerialization.data(withJSONObject: old).write(to: legacyFile)
        DraftStateMigration.adopt(from: [legacy], to: directory, renameItem: { _, _, _ in -1 }) {
            try FileManager.checked.copyItem(at: $0, to: $1)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: ".adopted-v1").path))
        try await AgentPaneQueuedEdits(directory: directory).clear(session: "session-a", prompt: "queue-a", revision: "owned")
        #expect(!FileManager.default.fileExists(atPath: queueFile.path))
        #expect(FileManager.default.fileExists(atPath: ownership.path))
        DraftStateMigration.adopt(from: [legacy], to: directory)
        #expect(try await AgentPaneQueuedEdits(directory: directory).read(session: "session-a") == .object([:]))
    }

    @Test func markerFailureLeavesCurrentDraftIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentPaneQueuedEdits(directory: directory)
        try await store.set(session: "s", prompt: "p", value: draft("current"))
        let marker = directory.appending(path: ".adopted-v1-\(AgentPaneQueuedEdits.fileName)")
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await store.clear(session: "s", prompt: "p", revision: "current")
        }
        #expect(try await store.read(session: "s") == .object(["p": draft("current")]))
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
