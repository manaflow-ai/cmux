import Foundation
import Testing

@testable import CmuxAgentSessionLabels

struct AgentSessionLabelStoreTests {
    private let now = Date(timeIntervalSince1970: 1_790_536_000)

    /// A store under a directory that does not exist yet, as a first run has it.
    private func makeStore() -> (AgentSessionLabelStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-agent-session-labels-\(UUID().uuidString)")
            .appendingPathComponent("state")
        let store = AgentSessionLabelStore.inStateDirectory(directory)
        return (store, directory.appendingPathComponent(AgentSessionLabelStore.fileName))
    }

    private func key(_ agent: String, _ sessionID: String) throws -> AgentSessionLabelKey {
        try AgentSessionLabelKey(agent: agent, sessionID: sessionID)
    }

    @Test func readsNoLabelsBeforeAnythingIsWritten() async throws {
        let (store, file) = makeStore()
        #expect(try await store.labels().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func writesAndReadsBackOneLabel() async throws {
        let (store, file) = makeStore()
        let session = try key("codex", "s-1")
        let written = try await store.setLabel("audit rows", for: session, now: now)
        #expect(written.text == "audit rows")
        #expect(try await store.label(for: session)?.text == "audit rows")
        #expect(try await store.label(for: session)?.updatedAt == now)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func storesTheTimeInAFormOnePersonCanRead() async throws {
        let (store, file) = makeStore()
        try await store.setLabel("audit rows", for: key("codex", "s-1"), now: now)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"updated_at\" : \"2026-09-27T"))
    }

    @Test func overwritingReplacesTheTextAndTheTime() async throws {
        let (store, _) = makeStore()
        let session = try key("codex", "s-1")
        try await store.setLabel("first", for: session, now: now)
        let later = now.addingTimeInterval(60)
        try await store.setLabel("second", for: session, now: later)
        let label = try await store.label(for: session)
        #expect(label?.text == "second")
        #expect(label?.updatedAt == later)
        #expect(try await store.labels().count == 1)
    }

    @Test func aRejectedLabelLeavesTheStoredOneAlone() async throws {
        let (store, _) = makeStore()
        let session = try key("codex", "s-1")
        try await store.setLabel("kept", for: session, now: now)
        await #expect(throws: AgentSessionLabelError.emptyLabel) {
            try await store.setLabel("  ", for: session, now: now)
        }
        #expect(try await store.label(for: session)?.text == "kept")
    }

    @Test func theSameSessionIDUnderTwoAgentsIsTwoLabels() async throws {
        let (store, _) = makeStore()
        try await store.setLabel("codex one", for: key("codex", "s-1"), now: now)
        try await store.setLabel("claude one", for: key("claude", "s-1"), now: now)
        #expect(try await store.label(for: key("codex", "s-1"))?.text == "codex one")
        #expect(try await store.label(for: key("claude", "s-1"))?.text == "claude one")
    }

    @Test func aSessionIDThatLooksLikeAPathIsStillARecord() async throws {
        let (store, file) = makeStore()
        let session = try key("codex", "../../escaped")
        try await store.setLabel("nowhere else", for: session, now: now)
        #expect(try await store.label(for: session)?.text == "nowhere else")
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: file.deletingLastPathComponent().path
        )
        #expect(siblings == [AgentSessionLabelStore.fileName])
    }

    @Test func clearingReportsWhetherThereWasALabel() async throws {
        let (store, _) = makeStore()
        let session = try key("codex", "s-1")
        try await store.setLabel("audit rows", for: session, now: now)
        #expect(try await store.clearLabel(for: session) == true)
        #expect(try await store.label(for: session) == nil)
        #expect(try await store.clearLabel(for: session) == false)
    }

    @Test func clearingOneAgentsLastLabelKeepsTheOtherAgents() async throws {
        let (store, file) = makeStore()
        try await store.setLabel("codex one", for: key("codex", "s-1"), now: now)
        try await store.setLabel("claude one", for: key("claude", "s-1"), now: now)
        #expect(try await store.clearLabel(for: key("codex", "s-1")) == true)
        let remaining = try await store.labels()
        #expect(remaining.count == 1)
        #expect(remaining[try key("claude", "s-1")]?.text == "claude one")
        // The emptied agent goes with its last label: a file that keeps growing
        // empty maps is a file nobody can read to see what is labelled.
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("codex"))
    }

    @Test func anEmptyFileIsNoLabels() async throws {
        let (store, file) = makeStore()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: file)
        #expect(try await store.labels().isEmpty)
    }

    @Test func aFileThatIsNotTheStoreFailsWithItsPath() async throws {
        let (store, file) = makeStore()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: file)
        await #expect(throws: AgentSessionLabelError.self) {
            try await store.labels()
        }
        let message = await errorMessage { try await store.labels() }
        #expect(message.contains(file.path))
    }

    @Test func aRecordThatIsNotAValidLabelNamesTheRecord() async throws {
        let (store, file) = makeStore()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("""
        {
          "version": 1,
          "agents": {
            "codex": {
              "s-1": { "label": "two\\nlines", "updated_at": "2026-09-27T21:46:40Z" }
            }
          }
        }
        """.utf8).write(to: file)
        let message = await errorMessage { try await store.labels() }
        #expect(message.contains("codex/s-1"))
    }

    @Test func aLaterSchemaVersionIsNotReadAsThisOne() async throws {
        let (store, file) = makeStore()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("""
        {"version": 2, "agents": {}}
        """.utf8).write(to: file)
        let message = await errorMessage { try await store.labels() }
        #expect(message.contains("version 2"))
    }

    /// The description of whatever the body throws, for the messages that have
    /// to name a path or a record rather than just fail.
    private func errorMessage(
        _ body: () async throws -> some Any
    ) async -> String {
        do {
            _ = try await body()
            return ""
        } catch {
            return String(describing: error)
        }
    }
}
