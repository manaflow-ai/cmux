import Foundation
import Testing

@testable import CmuxAgentSessionLabels

/// What one unreadable record, one foreign field or one odd key does to the rest.
///
/// The store's file is shared by every agent, and other programs write it too, so
/// these are the cases where being strict would cost a person their labels.
struct AgentSessionLabelStoreLeniencyTests {
    private let now = Date(timeIntervalSince1970: 1_790_536_000)

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

    /// Writes `json` as the store's file, creating its directory first.
    private func seed(_ file: URL, _ json: String) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(json.utf8).write(to: file)
    }

    @Test func aRecordFiledUnderAPaddedKeyIsReportedRatherThanReturned() async throws {
        let (store, file) = makeStore()
        try seed(file, """
        {
          "version": 1,
          "agents": {
            "codex ": {
              "s-1": { "label": "padded agent", "updated_at": "2026-09-27T21:46:40Z" }
            },
            "claude": {
              " s-2": { "label": "padded session", "updated_at": "2026-09-27T21:46:40Z" },
              "s-3": { "label": "reachable", "updated_at": "2026-09-27T21:46:40Z" }
            }
          }
        }
        """)
        let snapshot = try await store.snapshot()
        // Returning these would hand back a label that no write updates and no
        // clear removes, because both address a record by the trimmed key.
        #expect(snapshot.labels.count == 1)
        #expect(snapshot.labels[try key("claude", "s-3")]?.text == "reachable")
        #expect(snapshot.unreadableRecords.map(\.summary) == [
            "claude/ s-2: a session label's session id is stored with surrounding "
                + "whitespace, so no command could address this record",
            "codex /s-1: a session label's agent is stored with surrounding "
                + "whitespace, so no command could address this record",
        ])
    }

    @Test func aPaddedKeyDoesNotShadowTheRecordAWriteOwns() async throws {
        let (store, file) = makeStore()
        try seed(file, """
        {
          "version": 1,
          "agents": {
            "codex": {
              " s-1": { "label": "twin", "updated_at": "2026-09-27T21:46:40Z" },
              "s-1": { "label": "the one writes reach", "updated_at": "2026-09-27T21:46:40Z" }
            }
          }
        }
        """)
        let session = try key("codex", "s-1")
        #expect(try await store.label(for: session)?.text == "the one writes reach")
        try await store.setLabel("replaced", for: session, now: now)
        let snapshot = try await store.snapshot()
        #expect(snapshot.labels[session]?.text == "replaced")
        #expect(snapshot.unreadableRecords.count == 1)
    }

    @Test(
        "Each shape a record can be wrong in names itself and leaves the others alone",
        arguments: [
            ("7", "the record is not a JSON object"),
            ("{ \"updated_at\": \"2026-09-27T21:46:40Z\" }", "it has no label"),
            ("{ \"label\": 4, \"updated_at\": \"2026-09-27T21:46:40Z\" }", "its label is not a string"),
            ("{ \"label\": \"x\" }", "it has no updated_at"),
            ("{ \"label\": \"x\", \"updated_at\": 5 }", "its updated_at is not a string"),
            (
                "{ \"label\": \"x\", \"updated_at\": \"yesterday\" }",
                "yesterday is not an ISO 8601 timestamp"
            ),
        ]
    )
    func aRecordShapeThisBuildCannotReadIsSkipped(record: String, reason: String) async throws {
        let (store, file) = makeStore()
        try seed(file, """
        {
          "version": 1,
          "agents": {
            "codex": { "s-1": \(record) },
            "claude": {
              "s-9": { "label": "still readable", "updated_at": "2026-09-27T21:46:40Z" }
            }
          }
        }
        """)
        let snapshot = try await store.snapshot()
        #expect(snapshot.labels[try key("claude", "s-9")]?.text == "still readable")
        #expect(snapshot.labels.count == 1)
        #expect(snapshot.unreadableRecords.map(\.summary) == ["codex/s-1: \(reason)"])
    }

    @Test func anAgentWhoseRecordsAreNotAnObjectIsReportedUnderNoSession() async throws {
        let (store, file) = makeStore()
        try seed(file, """
        {
          "version": 1,
          "agents": {
            "codex": "not a set of records",
            "claude": {
              "s-9": { "label": "still readable", "updated_at": "2026-09-27T21:46:40Z" }
            }
          }
        }
        """)
        let snapshot = try await store.snapshot()
        #expect(snapshot.labels.count == 1)
        // There is no session id to report it under, and dropping it silently
        // would leave a listing that says this agent has no labels at all.
        #expect(snapshot.unreadableRecords.map(\.summary)
            == ["codex/: its records are not a JSON object"])
    }

    @Test func aTimestampWithNoZoneIsReadAsUTC() async throws {
        let (store, file) = makeStore()
        // What Python's `datetime.now().isoformat()` writes, which is what an
        // agent script reaching for this file is most likely to use.
        try seed(file, """
        {
          "version": 1,
          "agents": {
            "codex": {
              "s-1": { "label": "from a script", "updated_at": "2026-09-27T19:06:40.123456" }
            }
          }
        }
        """)
        let snapshot = try await store.snapshot()
        #expect(snapshot.unreadableRecords.isEmpty)
        #expect(snapshot.labels[try key("codex", "s-1")]?.updatedAt == now)
    }

    @Test func aWriteKeepsWhatItDoesNotUnderstand() async throws {
        let (store, file) = makeStore()
        try seed(file, """
        {
          "version": 1,
          "agents": {
            "codex": {
              "s-1": {
                "label": "kept",
                "updated_at": "2026-09-27T21:46:40Z",
                "color": "blue"
              },
              "s-2": { "label": 4, "updated_at": "2026-09-27T21:46:40Z" }
            },
            "weird": "not a set of records"
          },
          "generated_by": "some other program"
        }
        """)
        try await store.setLabel("added", for: key("codex", "s-3"), now: now)
        let text = try String(contentsOf: file, encoding: .utf8)
        // Another program's fields and records are its own. A rewrite that
        // dropped them would make this file unusable for anyone but cmux.
        #expect(text.contains("\"color\" : \"blue\""))
        #expect(text.contains("\"label\" : 4"))
        #expect(text.contains("\"weird\" : \"not a set of records\""))
        #expect(text.contains("\"added\""))
        let snapshot = try await store.snapshot()
        #expect(snapshot.labels[try key("codex", "s-1")]?.text == "kept")
        #expect(snapshot.labels[try key("codex", "s-3")]?.text == "added")
        #expect(snapshot.unreadableRecords.map(\.agent) == ["codex", "weird"])
    }

    @Test func overwritingOneLabelKeepsTheRestOfItsRecord() async throws {
        let (store, file) = makeStore()
        try seed(file, """
        {
          "version": 1,
          "agents": {
            "codex": {
              "s-1": {
                "label": "before",
                "updated_at": "2026-09-27T21:46:40Z",
                "color": "blue"
              }
            }
          }
        }
        """)
        try await store.setLabel("after", for: key("codex", "s-1"), now: now.addingTimeInterval(60))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"color\" : \"blue\""))
        #expect(text.contains("\"label\" : \"after\""))
        #expect(!text.contains("before"))
    }

    @Test func aWriteReplacesTheFileRatherThanEditingItInPlace() async throws {
        let (store, file) = makeStore()
        try await store.setLabel("first", for: key("codex", "s-1"), now: now)
        let manager = FileManager.default
        let before = try manager.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        try await store.setLabel("second", for: key("codex", "s-2"), now: now)
        let after = try manager.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        // A rename onto the path gives the reader, which takes no lock, either
        // the old document or the whole new one. Writing in place would let it
        // read a truncated file, and an in-place write keeps the inode.
        #expect(before != nil)
        #expect(before != after)
    }

    @Test func theLockLandsBesideTheFileAWriteActuallyTouches() async throws {
        let (store, file) = makeStore()
        let manager = FileManager.default
        let real = file.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("real-state")
        try manager.createDirectory(at: real, withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            at: file.deletingLastPathComponent(), withDestinationURL: real
        )

        try await store.setLabel("audit rows", for: key("codex", "s-1"), now: now)

        // Two processes reaching this file through different symlinks have to
        // take one lock, so the sidecar belongs next to the resolved file.
        let sidecar = real.appendingPathComponent(
            AgentSessionLabelStore.fileName + AgentSessionLabelStoreLock.fileSuffix
        )
        #expect(manager.fileExists(atPath: sidecar.path))
        #expect(manager.fileExists(
            atPath: real.appendingPathComponent(AgentSessionLabelStore.fileName).path
        ))
        #expect(try await store.label(for: key("codex", "s-1"))?.text == "audit rows")
    }

    @Test func skippedRecordsAreOrderedWhateverOrderTheyArrivedIn() {
        let records = [
            AgentSessionLabelSnapshot.UnreadableRecord(agent: "codex", sessionID: "s-2", reason: "a"),
            AgentSessionLabelSnapshot.UnreadableRecord(agent: "claude", sessionID: "s-9", reason: "b"),
            AgentSessionLabelSnapshot.UnreadableRecord(agent: "codex", sessionID: "s-1", reason: "c"),
            AgentSessionLabelSnapshot.UnreadableRecord(agent: "claude", sessionID: "s-1", reason: "d"),
        ]
        // A dictionary hands its pairs over in no order, so the snapshot's own
        // ordering is what makes two reads of one file report the same list.
        #expect(AgentSessionLabelSnapshot.ordered(records).map(\.summary) == [
            "claude/s-1: d", "claude/s-9: b", "codex/s-1: c", "codex/s-2: a",
        ])
    }
}
