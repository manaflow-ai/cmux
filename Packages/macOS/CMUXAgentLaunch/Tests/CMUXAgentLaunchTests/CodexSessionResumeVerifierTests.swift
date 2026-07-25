import Foundation
import SQLite3
import Testing
@testable import CMUXAgentLaunch

@Suite(.serialized)
struct CodexSessionResumeVerifierTests {
    @Test func indexedThreadWithExistingRolloutIsResumable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionId = "019f656e-cb8a-7ff2-9bef-81bf82fd6cb3"
        let rollout = try fixture.writeRollout(sessionId: sessionId)
        try fixture.insertThread(sessionId: sessionId, rolloutPath: rollout.path)

        let evidence = CodexSessionResumeVerifier().evidence(
            sessionId: sessionId,
            transcriptPath: nil,
            codexHome: fixture.codexHome.path
        )
        #expect(evidence == CodexSessionResumeEvidence(rolloutPath: rollout.path, source: .threadIndex))
    }

    @Test func unindexedReviewIdentifierIsNotResumable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let evidence = CodexSessionResumeVerifier().evidence(
            sessionId: "019f6dbc-5095-74f3-8035-ab8cdf772bb7",
            transcriptPath: nil,
            codexHome: fixture.codexHome.path
        )
        #expect(evidence == nil)
    }

    @Test func indexedSubagentResolvesToUserOwnedParent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let parentSessionId = "019f652f-e1c3-7521-859c-5f57e33b4c80"
        let childSessionId = "019f8c3d-72d0-7d91-8714-4bf5e541cb4d"
        let parentRollout = try fixture.writeRollout(sessionId: parentSessionId)
        let childRollout = try fixture.writeRollout(
            sessionId: childSessionId,
            parentSessionId: parentSessionId
        )
        try fixture.insertThread(
            sessionId: parentSessionId,
            rolloutPath: parentRollout.path,
            threadSource: "user"
        )
        try fixture.insertThread(
            sessionId: childSessionId,
            rolloutPath: childRollout.path,
            threadSource: "subagent"
        )

        let evidence = CodexSessionResumeVerifier().evidence(
            sessionId: childSessionId,
            transcriptPath: childRollout.path,
            codexHome: fixture.codexHome.path
        )

        #expect(evidence?.rolloutPath == parentRollout.path)
    }

    @Test func legacyRolloutRequiresMatchingSessionMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionId = "019f656e-cb8a-7ff2-9bef-81bf82fd6cb3"
        let rollout = try fixture.writeRollout(sessionId: sessionId)
        let verifier = CodexSessionResumeVerifier()
        #expect(verifier.evidence(
            sessionId: sessionId,
            transcriptPath: rollout.path,
            codexHome: fixture.root.appendingPathComponent("missing-codex-home").path
        )?.source == .legacyRollout)
        #expect(verifier.evidence(
            sessionId: "019f6dbc-5095-74f3-8035-ab8cdf772bb7",
            transcriptPath: rollout.path,
            codexHome: fixture.root.appendingPathComponent("missing-codex-home").path
        ) == nil)
    }

    private final class Fixture {
        let root: URL
        let codexHome: URL
        private let database: OpaquePointer

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-codex-resume-verifier-\(UUID().uuidString)", isDirectory: true)
            codexHome = root.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            var opened: OpaquePointer?
            let path = codexHome.appendingPathComponent("state_5.sqlite").path
            guard sqlite3_open(path, &opened) == SQLITE_OK, let opened else {
                throw FixtureError.database
            }
            database = opened
            guard sqlite3_exec(
                database,
                """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    rollout_path TEXT NOT NULL,
                    thread_source TEXT
                )
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw FixtureError.database
            }
        }

        deinit {
            sqlite3_close(database)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func writeRollout(sessionId: String, parentSessionId: String? = nil) throws -> URL {
            let rollout = root.appendingPathComponent("rollout-2026-07-16T19-29-41-\(sessionId).jsonl")
            var payload: [String: Any] = ["id": sessionId]
            if let parentSessionId {
                payload["session_id"] = parentSessionId
                payload["parent_thread_id"] = parentSessionId
                payload["forked_from_id"] = parentSessionId
                payload["source"] = [
                    "subagent": [
                        "thread_spawn": [
                            "parent_thread_id": parentSessionId,
                            "depth": 1,
                        ],
                    ],
                ]
            }
            let metadata: [String: Any] = [
                "type": "session_meta",
                "payload": payload,
            ]
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            try data.write(to: rollout, options: .atomic)
            return rollout
        }

        func insertThread(
            sessionId: String,
            rolloutPath: String,
            threadSource: String? = nil
        ) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO threads (id, rollout_path, thread_source) VALUES (?, ?, ?)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else {
                throw FixtureError.database
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, sessionId, -1, transient)
            sqlite3_bind_text(statement, 2, rolloutPath, -1, transient)
            if let threadSource {
                sqlite3_bind_text(statement, 3, threadSource, -1, transient)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.database }
        }
    }

    private enum FixtureError: Error {
        case database
    }
}
