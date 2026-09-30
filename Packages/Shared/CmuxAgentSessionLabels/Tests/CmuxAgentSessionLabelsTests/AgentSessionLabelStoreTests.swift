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
        ).sorted()
        // The store file and the lock beside it, and nothing named after the
        // session: a `..` in a session id addresses a record, never a path.
        #expect(siblings == [
            AgentSessionLabelStore.fileName,
            AgentSessionLabelStore.fileName + AgentSessionLabelStoreLock.fileSuffix
        ])
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

    @Test func anEmptyFileIsNotReadAsNoLabels() async throws {
        let (store, file) = makeStore()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: file)
        // A zero-length file is what a crash between rename and flush leaves, and
        // what `> file` leaves. Reading it as no labels would make the next write
        // delete every record the file used to hold.
        let message = await errorMessage { try await store.labels() }
        #expect(message == "\(file.path) is not a readable session label store: the file is empty")
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

    @Test func aRecordThatIsNotAValidLabelIsSkippedAndNamed() async throws {
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
            },
            "claude": {
              "s-9": { "label": "still readable", "updated_at": "2026-09-27T21:46:40Z" }
            }
          }
        }
        """.utf8).write(to: file)
        // One bad record must not hide the rest: every agent's labels share this
        // file, so throwing here would blank a whole listing over one row.
        let snapshot = try await store.snapshot()
        #expect(snapshot.labels.count == 1)
        #expect(snapshot.labels[try key("claude", "s-9")]?.text == "still readable")
        #expect(snapshot.unreadableRecords.count == 1)
        #expect(snapshot.unreadableRecords.first?.agent == "codex")
        #expect(snapshot.unreadableRecords.first?.sessionID == "s-1")
        #expect(snapshot.unreadableRecords.first?.summary
            == "codex/s-1: a session label cannot contain U+000A")
    }

    @Test func skippedRecordsComeBackInOneOrder() async throws {
        let (store, file) = makeStore()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("""
        {
          "version": 1,
          "agents": {
            "zeta": {
              "s-2": { "label": "two\\nlines", "updated_at": "2026-09-27T21:46:40Z" },
              "s-1": { "label": "two\\nlines", "updated_at": "2026-09-27T21:46:40Z" }
            },
            "alpha": {
              "s-1": { "label": "two\\nlines", "updated_at": "2026-09-27T21:46:40Z" }
            }
          }
        }
        """.utf8).write(to: file)
        // A caller prints these, and dictionary order changes between runs. Without
        // one order the same broken file reports its rows differently each read.
        let snapshot = try await store.snapshot()
        #expect(snapshot.unreadableRecords.map(\.summary) == [
            "alpha/s-1: a session label cannot contain U+000A",
            "zeta/s-1: a session label cannot contain U+000A",
            "zeta/s-2: a session label cannot contain U+000A"
        ])
    }

    @Test func aRecordWrittenByAnotherLanguageStillReads() async throws {
        let (store, file) = makeStore()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // `new Date().toISOString()` and `datetime.isoformat()` both carry
        // fractional seconds. Refusing them would take the whole document down
        // over a timestamp cmux itself would never write.
        try Data("""
        {
          "version": 1,
          "agents": {
            "codex": {
              "s-1": { "label": "from a hook", "updated_at": "2026-09-27T21:46:40.517Z" }
            }
          }
        }
        """.utf8).write(to: file)
        let label = try await store.label(for: key("codex", "s-1"))
        #expect(label?.text == "from a hook")
        #expect(label?.updatedAt == Date(timeIntervalSince1970: 1_790_545_600))
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

    @Test func aDocumentWithNoVersionSaysSo() async throws {
        let (store, file) = makeStore()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{\"agents\": {}}".utf8).write(to: file)
        let message = await errorMessage { try await store.labels() }
        #expect(message.contains("it has no version"))
    }

    @Test func aLaterSchemaVersionIsNamedEvenWhenItsBodyChanged() async throws {
        let (store, file) = makeStore()
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // The only reason to bump the version is a shape change, so the version
        // has to be read before the body it no longer matches.
        try Data("{\"version\": 2, \"labels\": {}}".utf8).write(to: file)
        let message = await errorMessage { try await store.labels() }
        #expect(message.contains("version 2"))
    }

    @Test func whatSetLabelReturnsIsWhatALaterReadReturns() async throws {
        let (store, _) = makeStore()
        let session = try key("codex", "s-1")
        // No fixed `now`: the default is the path every caller outside a test
        // takes, and a sub-second time would not survive the file.
        let written = try await store.setLabel("audit rows", for: session)
        let readBack = try await store.label(for: session)
        #expect(readBack == written)
    }

    @Test func labelsAreWrittenInOneOrderSoTheFileCanBeDiffed() async throws {
        let (store, file) = makeStore()
        for agent in ["zeta", "mu", "delta", "beta", "alpha"] {
            try await store.setLabel("row", for: key(agent, "s-1"), now: now)
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        let positions = ["alpha", "beta", "delta", "mu", "zeta"].compactMap {
            text.range(of: "\"\($0)\"")?.lowerBound
        }
        #expect(positions.count == 5)
        #expect(positions == positions.sorted())
    }

    @Test func aStoreSymlinkedIntoADotfilesDirectoryStaysALink() async throws {
        let (store, file) = makeStore()
        let manager = FileManager.default
        let directory = file.deletingLastPathComponent()
        let dotfiles = directory.deletingLastPathComponent().appendingPathComponent("dotfiles")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent(AgentSessionLabelStore.fileName)
        try Data("{\"version\": 1, \"agents\": {}}".utf8).write(to: target)
        try manager.createSymbolicLink(at: file, withDestinationURL: target)

        try await store.setLabel("audit rows", for: key("codex", "s-1"), now: now)

        // An atomic write renames onto the path, which would replace the link
        // with a plain file and quietly detach the dotfiles copy.
        let attributes = try manager.attributesOfItem(atPath: file.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let throughTarget = try String(contentsOf: target, encoding: .utf8)
        #expect(throughTarget.contains("audit rows"))
    }

    @Test func aStorePathThatIsADirectoryFailsAsUnreadable() async throws {
        let (store, file) = makeStore()
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let message = await errorMessage { try await store.labels() }
        // Not a malformed store: the content is not the problem, and a caller
        // that prints this needs the sentence rather than an NSError dump.
        #expect(message.hasPrefix("\(file.path) could not be read:"))
        #expect(!message.contains("UserInfo"))
        #expect(!message.contains("Error Domain"))
        #expect(!message.contains("\n"))
    }

    /// The description of whatever the body throws, for the messages that have
    /// to name a path or a record rather than just fail.
    private func errorMessage(
        _ body: () async throws -> some Any
    ) async -> String {
        do {
            _ = try await body()
            return ""
        } catch let error as AgentSessionLabelError {
            return error.description
        } catch {
            return String(describing: error)
        }
    }
}
