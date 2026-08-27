import Foundation
import SQLite3
import Testing
@testable import CMUXAgentLaunch

/// Durable Codex binding fixtures.  Nothing in this suite reads the developer's
/// real ~/.codex directory: every rollout and state database is under Fixture.root.
@Suite(.serialized)
struct CodexResumeBindingVerificationTests {
    @Test func ephemeralIdentifierWithoutRolloutIsMissing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = CodexSessionResumeVerifier().verify(
            sessionId: "019ff9a1-cbe1-7231-9478-0c55a8c44560",
            transcriptPath: nil,
            codexHome: fixture.codexHome.path
        )

        #expect(result == .missing)
    }

    @Test func batchLegacyVerificationWalksOneHomeForMultipleIdentities() throws {
        let fixture = try Fixture(createIndex: false)
        defer { fixture.remove() }

        let firstID = "019ff9a5-cbe1-7231-9478-0c55a8c44560"
        let secondID = "019ff9a6-cbe1-7231-9478-0c55a8c44560"
        let firstRollout = try fixture.writeRollout(
            sessionId: firstID,
            source: "cli",
            originator: "codex-tui"
        )
        let secondRollout = try fixture.writeRollout(
            sessionId: secondID,
            source: "cli",
            originator: "codex-tui"
        )

        let results = CodexSessionResumeVerifier().verifyBatch(
            [
                CodexSessionResumeVerificationRequest(sessionId: firstID),
                CodexSessionResumeVerificationRequest(sessionId: secondID),
                CodexSessionResumeVerificationRequest(sessionId: "missing-batch-id"),
            ],
            codexHome: fixture.codexHome.path
        )

        guard results.count == 3,
              case .exists(let firstEvidence) = results[0],
              case .exists(let secondEvidence) = results[1] else {
            Issue.record("one legacy batch should resolve every exact rollout")
            return
        }
        #expect(URL(fileURLWithPath: firstEvidence.rolloutPath).lastPathComponent == firstRollout.lastPathComponent)
        #expect(URL(fileURLWithPath: secondEvidence.rolloutPath).lastPathComponent == secondRollout.lastPathComponent)
        #expect(results[2] == .missing)
    }

    @Test func batchLegacyVerificationTrustsMetadataWhenFilenameNamesAnotherSession() throws {
        let fixture = try Fixture(createIndex: false)
        defer { fixture.remove() }

        let filenameSessionID = "019ff9a7-cbe1-7231-9478-0c55a8c44560"
        let metadataSessionID = "019ff9a8-cbe1-7231-9478-0c55a8c44560"
        _ = try fixture.writeRollout(
            sessionId: metadataSessionID,
            filename: "rollout-\(filenameSessionID)-renamed.jsonl",
            source: "cli",
            originator: "codex-tui"
        )

        let results = CodexSessionResumeVerifier().verifyBatch(
            [
                CodexSessionResumeVerificationRequest(sessionId: filenameSessionID),
                CodexSessionResumeVerificationRequest(sessionId: metadataSessionID),
            ],
            codexHome: fixture.codexHome.path
        )

        guard results.count == 2,
              case .exists(let evidence) = results[1] else {
            Issue.record("session_meta.id must remain authoritative after a rollout rename")
            return
        }
        #expect(evidence.sessionId == metadataSessionID)
        #expect(evidence.source == .legacyRollout)
    }

    @Test func batchVerificationMarksRequestsBeyondBoundUnavailable() throws {
        let fixture = try Fixture(createIndex: false)
        defer { fixture.remove() }

        let requests = (0...CodexSessionResumeVerificationLimits.maximumBatchRequests).map {
            CodexSessionResumeVerificationRequest(sessionId: "batch-session-\($0)")
        }
        let results = CodexSessionResumeVerifier().verifyBatch(
            requests,
            codexHome: fixture.codexHome.path
        )

        #expect(results.count == CodexSessionResumeVerificationLimits.maximumBatchRequests)
    }

    @Test func fallbackCandidateTruncationIsUnavailable() throws {
        let fixture = try Fixture(createIndex: false)
        defer { fixture.remove() }

        let directory = fixture.codexHome
            .appendingPathComponent("sessions/2026/08/12", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let event: [String: Any] = [
            "type": "event_msg",
            "payload": ["type": "task_started"],
        ]
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        for index in 0...512 {
            try data.write(
                to: directory.appendingPathComponent("unrelated-\(index).jsonl"),
                options: .atomic
            )
        }

        #expect(
            CodexSessionResumeVerifier().verify(
                sessionId: "fallback-candidate-cap-target",
                transcriptPath: nil,
                codexHome: fixture.codexHome.path
            ) == .unavailable
        )
    }

    @Test func codexHomeResolverPrefersLaunchMetadataOverAmbientState() {
        let resolver = CodexHomeResolver()
        let launchCodexHome = "/tmp/launch-codex"
        let launchUserHome = "/tmp/launch-user"
        let ambientCodexHome = "/tmp/ambient-codex"

        #expect(
            resolver.resolve(
                launchEnvironment: ["CODEX_HOME": launchCodexHome],
                launchVerificationHome: launchUserHome,
                ambientEnvironment: [
                    "CODEX_HOME": ambientCodexHome,
                    "HOME": "/tmp/ambient-user",
                ],
                fallbackHomeDirectory: "/tmp/fallback"
            ) == launchCodexHome
        )
        #expect(
            resolver.resolve(
                launchEnvironment: ["HOME": launchUserHome],
                ambientEnvironment: ["CODEX_HOME": ambientCodexHome],
                fallbackHomeDirectory: "/tmp/fallback"
            ) == "\(launchUserHome)/.codex"
        )
        #expect(
            resolver.resolve(
                launchEnvironment: ["CODEX_HOME": ".codex"],
                launchWorkingDirectory: "/tmp/captured-project",
                ambientEnvironment: ["CODEX_HOME": ambientCodexHome],
                fallbackHomeDirectory: "/tmp/fallback"
            ) == "/tmp/captured-project/.codex"
        )
    }

    @Test func readableIndexWithoutThreadDoesNotScanUnindexedRollouts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionID = "019ff9a2-cbe1-7231-9478-0c55a8c44560"
        _ = try fixture.writeRollout(
            sessionId: sessionID,
            source: "cli",
            originator: "codex-tui"
        )

        #expect(
            CodexSessionResumeVerifier().verify(
                sessionId: sessionID,
                transcriptPath: nil,
                codexHome: fixture.codexHome.path
            ) == .missing
        )
    }

    @Test func readableIndexWithoutThreadAcceptsExactTranscript() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionID = "019ff9a3-cbe1-7231-9478-0c55a8c44560"
        let transcript = try fixture.writeRollout(
            sessionId: sessionID,
            source: "cli",
            originator: "codex-tui"
        )

        guard case .exists(let evidence) = CodexSessionResumeVerifier().verify(
            sessionId: sessionID,
            transcriptPath: transcript.path,
            codexHome: fixture.codexHome.path
        ) else {
            Issue.record("an exact hook transcript should bridge an index write race")
            return
        }
        #expect(evidence.sessionId == sessionID)
        #expect(evidence.provenance == .tui)
    }

    @Test func rolloutOnlyLegacyInstallationStillFindsExactSession() throws {
        let fixture = try Fixture(createIndex: false)
        defer { fixture.remove() }

        let sessionID = "019ff9a4-cbe1-7231-9478-0c55a8c44560"
        let rollout = try fixture.writeRollout(
            sessionId: sessionID,
            source: "cli",
            originator: "codex-tui"
        )

        guard case .exists(let evidence) = CodexSessionResumeVerifier().verify(
            sessionId: sessionID,
            transcriptPath: nil,
            codexHome: fixture.codexHome.path
        ) else {
            Issue.record("rollout-only Codex installations must keep legacy discovery")
            return
        }
        #expect(URL(fileURLWithPath: evidence.rolloutPath).lastPathComponent == rollout.lastPathComponent)
        #expect(evidence.source == .legacyRollout)
        #expect(evidence.provenance == .tui)
    }

    @Test func unreadableThreadIndexIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-binding-unavailable-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not-a-sqlite-database".utf8).write(
            to: codexHome.appendingPathComponent("state_5.sqlite"),
            options: .atomic
        )

        #expect(
            CodexSessionResumeVerifier().verify(
                sessionId: "019ff9a8-cbe1-7231-9478-0c55a8c44560",
                transcriptPath: nil,
                codexHome: codexHome.path
        ) == .unavailable
        )
    }

    @Test func unreadableThreadIndexDoesNotAcceptTranscriptFallback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionID = "019ff9a9-cbe1-7231-9478-0c55a8c44560"
        let transcript = try fixture.writeRollout(
            sessionId: sessionID,
            source: "cli",
            originator: "codex-tui"
        )
        try Data("not-a-sqlite-database".utf8).write(
            to: fixture.codexHome.appendingPathComponent("state_5.sqlite"),
            options: .atomic
        )

        #expect(
            CodexSessionResumeVerifier().verify(
                sessionId: sessionID,
                transcriptPath: transcript.path,
                codexHome: fixture.codexHome.path
            ) == .unavailable
        )
    }

    @Test func indexedThreadWithUnreadableRolloutIsUnavailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionId = "019ff9a8-cbe1-7231-9478-0c55a8c44560"
        let rollout = fixture.codexHome
            .appendingPathComponent("sessions/2026/08/12/rollout-\(sessionId).jsonl")
        try FileManager.default.createDirectory(
            at: rollout.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fixture.insertThread(sessionId: sessionId, rolloutPath: rollout.path)

        #expect(
            CodexSessionResumeVerifier().verify(
                sessionId: sessionId,
                transcriptPath: nil,
                codexHome: fixture.codexHome.path
        ) == .unavailable
        )
    }

    @Test func indexedThreadWithMismatchedRolloutMetadataDoesNotUseFallbackEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let requestedSessionID = "019ff9aa-cbe1-7231-9478-0c55a8c44560"
        let indexedRollout = try fixture.writeRollout(
            sessionId: "019ff9ab-cbe1-7231-9478-0c55a8c44560"
        )
        let matchingTranscript = try fixture.writeRollout(sessionId: requestedSessionID)
        try fixture.insertThread(sessionId: requestedSessionID, rolloutPath: indexedRollout.path)

        #expect(
            CodexSessionResumeVerifier().verify(
                sessionId: requestedSessionID,
                transcriptPath: matchingTranscript.path,
                codexHome: fixture.codexHome.path
            ) == .unavailable
        )
    }

    @Test func indexedThreadWithoutSessionMetadataDoesNotUseFallbackEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionID = "019ff9ac-cbe1-7231-9478-0c55a8c44560"
        let indexedRollout = fixture.codexHome
            .appendingPathComponent("sessions/2026/08/12/indexed-\(sessionID).jsonl")
        try FileManager.default.createDirectory(
            at: indexedRollout.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let event: [String: Any] = [
            "type": "event_msg",
            "payload": ["type": "task_started"],
        ]
        try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            .write(to: indexedRollout, options: .atomic)
        let matchingTranscript = try fixture.writeRollout(sessionId: sessionID)
        try fixture.insertThread(sessionId: sessionID, rolloutPath: indexedRollout.path)

        #expect(
            CodexSessionResumeVerifier().verify(
                sessionId: sessionID,
                transcriptPath: matchingTranscript.path,
                codexHome: fixture.codexHome.path
            ) == .unavailable
        )
    }

    @Test func matchingFilenameProbeLimitFailsClosed() throws {
        let fixture = try Fixture(createIndex: false)
        defer { fixture.remove() }

        let sessionID = "019ff9ad-cbe1-7231-9478-0c55a8c44560"
        let directory = fixture.codexHome
            .appendingPathComponent("sessions/2026/08/12", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let event: [String: Any] = [
            "type": "event_msg",
            "payload": ["type": "task_started"],
        ]
        let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        for index in 0..<33 {
            let path = directory.appendingPathComponent("rollout-\(sessionID)-\(index).jsonl")
            try data.write(to: path, options: .atomic)
        }

        #expect(
            CodexSessionResumeVerifier().verify(
                sessionId: sessionID,
                transcriptPath: nil,
                codexHome: fixture.codexHome.path
            ) == .unavailable
        )
    }

    @Test func persistedExecRolloutIsDurableButLowerProvenance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionId = "019ff9b0-cbe1-7231-9478-0c55a8c44560"
        let rollout = try fixture.writeRollout(
            sessionId: sessionId,
            source: "exec",
            originator: "codex_exec"
        )
        try fixture.insertThread(sessionId: sessionId, rolloutPath: rollout.path)

        guard case .exists(let evidence) = CodexSessionResumeVerifier().verify(
            sessionId: sessionId,
            transcriptPath: rollout.path,
            codexHome: fixture.codexHome.path
        ) else {
            Issue.record("the persisted exec rollout must be observed before provenance rejects ownership")
            return
        }
        #expect(evidence.provenance == .exec)
        #expect(evidence.sessionId == sessionId)
    }

    @Test func legitimateTUIRolloutIsHighProvenance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionId = "019ff9c0-d827-7831-960d-fd9bdf7d54e2"
        let rollout = try fixture.writeRollout(
            sessionId: sessionId,
            source: "cli",
            originator: "codex-tui"
        )
        try fixture.insertThread(sessionId: sessionId, rolloutPath: rollout.path)

        guard case .exists(let evidence) = CodexSessionResumeVerifier().verify(
            sessionId: sessionId,
            transcriptPath: nil,
            codexHome: fixture.codexHome.path
        ) else {
            Issue.record("a real TUI rollout must be accepted")
            return
        }
        #expect(evidence.provenance == .tui)
        #expect(evidence.sessionId == sessionId)
    }

    @Test func vscodeRolloutIsTrustedTopLevelProvenance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionID = "019ff9c1-d827-7831-960d-fd9bdf7d54e2"
        let rollout = try fixture.writeRollout(
            sessionId: sessionID,
            source: "vscode",
            originator: "codex-vscode"
        )
        try fixture.insertThread(sessionId: sessionID, rolloutPath: rollout.path)

        guard case .exists(let evidence) = CodexSessionResumeVerifier().verify(
            sessionId: sessionID,
            transcriptPath: nil,
            codexHome: fixture.codexHome.path
        ) else {
            Issue.record("a VS Code top-level session must be accepted")
            return
        }
        #expect(evidence.provenance == .tui)
        #expect(evidence.provenance.mayOwnBinding)
    }

    @Test func threadIndexSourcePreventsLegacyExecFromOwningBinding() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionId = "019ff9c8-d827-7831-960d-fd9bdf7d54e2"
        let rollout = try fixture.writeRollout(sessionId: sessionId)
        try fixture.insertThread(
            sessionId: sessionId,
            rolloutPath: rollout.path,
            source: "\"exec\"",
            threadSource: "user"
        )

        guard case .exists(let evidence) = CodexSessionResumeVerifier().verify(
            sessionId: sessionId,
            transcriptPath: nil,
            codexHome: fixture.codexHome.path
        ) else {
            Issue.record("the indexed legacy rollout should remain durable evidence")
            return
        }
        #expect(evidence.provenance == .exec)
    }

    @Test func nestedReviewMarkerIsLowerProvenanceEvenWhenSourceIsNested() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionId = "019ff9d0-cbe1-7231-9478-0c55a8c44560"
        let rollout = try fixture.writeRollout(
            sessionId: sessionId,
            nestedSource: ["review": ["parent_thread_id": "parent"]]
        )
        try fixture.insertThread(sessionId: sessionId, rolloutPath: rollout.path)

        guard case .exists(let evidence) = CodexSessionResumeVerifier().verify(
            sessionId: sessionId,
            transcriptPath: rollout.path,
            codexHome: fixture.codexHome.path
        ) else {
            Issue.record("the nested rollout should be classified, not treated as absent")
            return
        }
        #expect(evidence.provenance == .exec)
    }

    @Test func ambiguousNestedParentMetadataDoesNotClaimAncestry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionID = "019ff9d1-cbe1-7231-9478-0c55a8c44560"
        let rollout = try fixture.writeRollout(
            sessionId: sessionID,
            nestedSource: [
                "review": ["parent_thread_id": "first-parent"],
                "metadata": ["parent_thread_id": "second-parent"],
            ]
        )
        try fixture.insertThread(sessionId: sessionID, rolloutPath: rollout.path)

        guard case .exists(let evidence) = CodexSessionResumeVerifier().verify(
            sessionId: sessionID,
            transcriptPath: rollout.path,
            codexHome: fixture.codexHome.path
        ) else {
            Issue.record("the rollout should still be classified as durable evidence")
            return
        }
        #expect(evidence.provenance == .exec)
        #expect(evidence.parentSessionId == nil)
    }

    @Test func transcriptWithoutExactSessionMetadataIsMissing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let sessionId = "019ff9e0-cbe1-7231-9478-0c55a8c44560"
        let transcript = fixture.codexHome.appendingPathComponent("legacy-transcript.jsonl")
        let unrelatedEvent: [String: Any] = [
            "type": "event_msg",
            "payload": ["type": "task_started"],
        ]
        let data = try JSONSerialization.data(withJSONObject: unrelatedEvent, options: [.sortedKeys])
        try data.write(to: transcript, options: .atomic)

        #expect(
            CodexSessionResumeVerifier().verify(
                sessionId: sessionId,
                transcriptPath: transcript.path,
                codexHome: fixture.codexHome.path
            ) == .missing
        )
    }

    @Test func provenanceReplacementPolicyRejectsChildrenAndDowngrades() {
        #expect(!AgentResumeEvidenceProvenance.exec.canReplace(nil))
        #expect(!AgentResumeEvidenceProvenance.subagent.canReplace(nil))
        #expect(!AgentResumeEvidenceProvenance.unknown.canReplace(nil))
        #expect(!AgentResumeEvidenceProvenance.unknown.canReplace(.tui))
        #expect(AgentResumeEvidenceProvenance.tui.canReplace(.unknown))
        #expect(AgentResumeEvidenceProvenance.tui.canReplace(.tui))
    }

    @Test func hermesExistenceContractRemainsUnchanged() throws {
        let fixture = try HermesFixture()
        defer { fixture.remove() }

        #expect(
            HermesAgentIndex.sessionExistence(
                sessionID: fixture.sessionID,
                stateDBPath: fixture.databaseURL.path
            ) == .exists
        )
        #expect(
            HermesAgentIndex.sessionExistence(
                sessionID: "missing-hermes-session",
                stateDBPath: fixture.databaseURL.path
            ) == .missing
        )
    }

    private final class Fixture {
        let root: URL
        let codexHome: URL
        private let database: OpaquePointer?

        init(createIndex: Bool = true) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-codex-binding-verifier-\(UUID().uuidString)", isDirectory: true)
            codexHome = root.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)

            guard createIndex else {
                database = nil
                return
            }

            var opened: OpaquePointer?
            let databasePath = codexHome.appendingPathComponent("state_5.sqlite").path
            guard sqlite3_open(databasePath, &opened) == SQLITE_OK, let opened else {
                throw FixtureError.database
            }
            database = opened
            guard sqlite3_exec(
                database,
                "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, source TEXT, thread_source TEXT)",
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw FixtureError.database
            }
        }

        deinit {
            if let database {
                sqlite3_close(database)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func writeRollout(
            sessionId: String,
            filename: String? = nil,
            source: String? = nil,
            originator: String? = nil,
            nestedSource: [String: Any]? = nil
        ) throws -> URL {
            let directory = codexHome.appendingPathComponent("sessions/2026/08/12", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var payload: [String: Any] = ["id": sessionId, "cwd": root.path]
            if let source { payload["source"] = source }
            if let originator { payload["originator"] = originator }
            if let nestedSource { payload["source"] = nestedSource }
            let line: [String: Any] = ["type": "session_meta", "payload": payload]
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            let url = directory.appendingPathComponent(filename ?? "rollout-\(sessionId).jsonl")
            try data.write(to: url, options: .atomic)
            return url
        }

        func insertThread(
            sessionId: String,
            rolloutPath: String,
            source: String? = nil,
            threadSource: String? = nil
        ) throws {
            guard let database else { throw FixtureError.database }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO threads (id, rollout_path, source, thread_source) VALUES (?, ?, ?, ?)",
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
            if let source {
                sqlite3_bind_text(statement, 3, source, -1, transient)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            if let threadSource {
                sqlite3_bind_text(statement, 4, threadSource, -1, transient)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.database }
        }
    }

    private final class HermesFixture {
        let root: URL
        let databaseURL: URL
        let sessionID = "hermes-tui-session"
        private let database: OpaquePointer

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-hermes-binding-verifier-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            databaseURL = root.appendingPathComponent("state.db")
            var opened: OpaquePointer?
            guard sqlite3_open(databaseURL.path, &opened) == SQLITE_OK, let opened else {
                throw FixtureError.database
            }
            database = opened
            let schema = """
                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY,
                    source TEXT NOT NULL,
                    title TEXT,
                    model TEXT,
                    started_at REAL,
                    ended_at REAL,
                    cwd TEXT
                );
                CREATE TABLE messages (
                    id INTEGER PRIMARY KEY,
                    session_id TEXT,
                    timestamp REAL,
                    role TEXT,
                    content TEXT,
                    tool_name TEXT
                );
                INSERT INTO sessions (id, source, title, started_at, cwd)
                    VALUES ('hermes-tui-session', 'tui', 'fixture', 1, '/tmp');
                """
            guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.database
            }
        }

        deinit { sqlite3_close(database) }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private enum FixtureError: Error { case database }
}
