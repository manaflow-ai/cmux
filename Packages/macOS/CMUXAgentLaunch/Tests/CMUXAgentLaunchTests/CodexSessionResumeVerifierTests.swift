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
                "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL)",
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

        func writeRollout(sessionId: String) throws -> URL {
            let rollout = root.appendingPathComponent("rollout-2026-07-16T19-29-41-\(sessionId).jsonl")
            try #"{"type":"session_meta","payload":{"id":"\#(sessionId)"}}"#
                .write(to: rollout, atomically: true, encoding: .utf8)
            return rollout
        }

        func insertThread(sessionId: String, rolloutPath: String) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO threads (id, rollout_path) VALUES (?, ?)",
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
            guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.database }
        }
    }

    private enum FixtureError: Error {
        case database
    }
}
