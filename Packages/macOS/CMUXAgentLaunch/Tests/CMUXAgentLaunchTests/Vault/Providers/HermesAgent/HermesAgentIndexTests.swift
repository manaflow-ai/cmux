@testable import CMUXAgentLaunch
import Foundation
import SQLite3
import Testing

@Suite("HermesAgentIndex")
struct HermesAgentIndexTests {
    @Test("Loads CLI and TUI sessions from state database")
    func loadsCliAndTUISessions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)

        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES
          ('old', 'cli', 'model-a', 10, 'Old session'),
          ('new', 'tui', 'model-b', 20, NULL),
          ('tool-only', 'tool', 'model-c', 30, 'Hidden tool session');
        INSERT INTO messages (session_id, role, content, timestamp)
        VALUES
          ('old', 'user', 'older prompt', 11),
          ('new', 'user', 'new prompt first line', 21),
          ('new', 'assistant', 'new answer', 22),
          ('tool-only', 'user', 'hidden', 31);
        """)

        let result = HermesAgentIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )

        #expect(result.errors.isEmpty)
        #expect(result.sessions.map(\.sessionId) == ["new", "old"])
        #expect(result.sessions.first?.source == "tui")
        #expect(result.sessions.first?.title == "new answer")
        #expect(result.sessions.first?.modified == Date(timeIntervalSince1970: 22))
    }

    @Test("Loads a checkpointed WAL database after Hermes removes its sidecars")
    func loadsCheckpointedWALDatabaseWithoutSidecars() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)

        try exec(dbURL, "PRAGMA journal_mode = WAL;")
        try makeHermesStateDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('wal-session', 'tui', 'model-a', 10, 'WAL session');
        PRAGMA wal_checkpoint(TRUNCATE);
        """)

        for sidecar in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: dbURL.path + sidecar)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try FileManager.default.removeItem(at: sidecarURL)
            }
        }

        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: dbURL.path + "-shm"))

        let result = HermesAgentIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )

        #expect(result.errors.isEmpty)
        #expect(result.sessions.map(\.sessionId) == ["wal-session"])
    }

    @Test("Recovers a transient Hermes TUI transport ID from the durable state database")
    func recoversTransientTUITransportID() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hermesHome = root.appendingPathComponent(".hermes", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let dbURL = hermesHome.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title, cwd)
        VALUES
          ('20260807_185008_923dfc', 'tui', 'model-a', 116, 'Recovered', '\(repo.path)'),
          ('20260807_185500_too-late', 'tui', 'model-a', 250, 'Next process', '\(repo.path)');
        """)

        let workspaceID = UUID()
        let surfaceID = UUID()
        let transportID = "96dd0dcc"
        let hookStoreURL = root.appendingPathComponent("hermes-agent-hook-sessions.json")
        let hookStore = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [
                    transportID: [
                        "sessionId": transportID,
                        "workspaceId": workspaceID.uuidString,
                        "surfaceId": surfaceID.uuidString,
                        "cwd": repo.path,
                        "pid": 12_345,
                        "pidStartSeconds": 100,
                        "pidStartMicroseconds": 200,
                        "startedAt": 100.0,
                        "updatedAt": 101.0,
                    ],
                    "next-transport": [
                        "sessionId": "next-transport",
                        "workspaceId": workspaceID.uuidString,
                        "surfaceId": surfaceID.uuidString,
                        "cwd": repo.path,
                        "pid": 67_890,
                        "pidStartSeconds": 300,
                        "pidStartMicroseconds": 400,
                        "startedAt": 200.0,
                        "updatedAt": 201.0,
                    ],
                ],
            ],
            options: [.sortedKeys]
        )
        try hookStore.write(to: hookStoreURL)

        let recovered = HermesLegacySessionIdentityRecovery().recover(
            surfaceID: surfaceID,
            corruptSessionID: transportID,
            expectedWorkspaceID: workspaceID,
            hookStateFileURL: hookStoreURL,
            environment: ["HOME": root.path]
        )

        #expect(recovered?.sessionID == "20260807_185008_923dfc")
    }

    @Test("Inspects one Hermes database snapshot for every unique candidate path")
    func recoveryBatchesCandidatesByDatabasePath() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceID = UUID()
        let surfaceID = UUID()
        let transportID = "96dd0dcc"
        let durableID = "20260807_185008_923dfc"
        let rejectedIDs = ["20260807_185009_rejected", "20260807_185010_rejected"]
        let hookStoreURL = root.appendingPathComponent("hermes-agent-hook-sessions.json")

        var sessions: [String: [String: Any]] = [:]
        for (offset, sessionID) in ([transportID, durableID] + rejectedIDs).enumerated() {
            sessions[sessionID] = [
                "sessionId": sessionID,
                "workspaceId": workspaceID.uuidString,
                "surfaceId": surfaceID.uuidString,
                "cwd": root.path,
                "pid": 12_345,
                "pidStartSeconds": 100,
                "pidStartMicroseconds": 200,
                "startedAt": 100.0,
                "updatedAt": 101.0 + Double(offset),
            ]
        }
        let hookStore = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": sessions],
            options: [.sortedKeys]
        )
        try hookStore.write(to: hookStoreURL)

        var inspectedPaths: [String] = []
        let recovered = HermesLegacySessionIdentityRecovery().recover(
            surfaceID: surfaceID,
            corruptSessionID: transportID,
            expectedWorkspaceID: workspaceID,
            hookStateFileURL: hookStoreURL,
            environment: ["HOME": root.path],
            databaseInspector: { sessionIDs, _, _, _, stateDBPath in
                inspectedPaths.append(stateDBPath)
                #expect(sessionIDs == Set([transportID, durableID] + rejectedIDs))
                return HermesAgentIndex.RecoveryInspection(
                    existingSessionIDs: [durableID],
                    evidence: []
                )
            }
        )

        #expect(recovered?.sessionID == durableID)
        #expect(inspectedPaths.count == 1)
    }

    @Test("Unavailable Hermes databases never guess a legacy restore identity")
    func unavailableDatabaseFailsClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceID = UUID()
        let surfaceID = UUID()
        let corruptID = surfaceID.uuidString
        let durableID = "20260807_185008_923dfc"
        let hookStoreURL = root.appendingPathComponent("hermes-agent-hook-sessions.json")
        let commonRecord: [String: Any] = [
            "workspaceId": workspaceID.uuidString,
            "surfaceId": surfaceID.uuidString,
            "cwd": root.path,
            "pid": 12_345,
            "pidStartSeconds": 100,
            "pidStartMicroseconds": 200,
            "startedAt": 100.0,
        ]
        var corruptRecord = commonRecord
        corruptRecord["sessionId"] = corruptID
        corruptRecord["updatedAt"] = 101.0
        var durableRecord = commonRecord
        durableRecord["sessionId"] = durableID
        durableRecord["updatedAt"] = 102.0
        let hookStore = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [corruptID: corruptRecord, durableID: durableRecord],
            ],
            options: [.sortedKeys]
        )
        try hookStore.write(to: hookStoreURL)

        var inspectionCount = 0
        let resolution = HermesLegacySessionIdentityRecovery().resolve(
            surfaceID: surfaceID,
            corruptSessionID: corruptID,
            expectedWorkspaceID: workspaceID,
            hookStateFileURL: hookStoreURL,
            environment: ["HOME": root.path],
            databaseInspector: { _, _, _, _, _ in
                inspectionCount += 1
                return nil
            }
        )

        #expect(resolution == .unavailable)
        #expect(inspectionCount == 1)
    }

    @Test("Re-arms a durable Hermes checkpoint after its hook row moves to another pane")
    func rearmDurableCheckpointAfterHookRecordReuse() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let originalWorkspaceID = UUID()
        let originalSurfaceID = UUID()
        let replacementWorkspaceID = UUID()
        let replacementSurfaceID = UUID()
        let durableID = "20260807_192611_076701"
        let transientID = originalSurfaceID.uuidString
        let hookStoreURL = root.appendingPathComponent("hermes-agent-hook-sessions.json")

        let hookStore = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": [
                    durableID: [
                        "sessionId": durableID,
                        "workspaceId": replacementWorkspaceID.uuidString,
                        "surfaceId": replacementSurfaceID.uuidString,
                        "cwd": root.path,
                        "pid": 67_890,
                        "pidStartSeconds": 300,
                        "pidStartMicroseconds": 400,
                        "runtimeStatus": "idle",
                        "agentLifecycle": "idle",
                        "startedAt": 200.0,
                        "updatedAt": 201.0,
                    ],
                    transientID: [
                        "sessionId": transientID,
                        "workspaceId": originalWorkspaceID.uuidString,
                        "surfaceId": originalSurfaceID.uuidString,
                        "cwd": root.path,
                        "pid": 12_345,
                        "pidStartSeconds": 100,
                        "pidStartMicroseconds": 200,
                        "runtimeStatus": "running",
                        "agentLifecycle": "running",
                        "startedAt": 100.0,
                        "updatedAt": 101.0,
                    ],
                ],
            ],
            options: [.sortedKeys]
        )
        try hookStore.write(to: hookStoreURL)

        var inspectedSessionIDs: [Set<String>] = []
        let resolution = HermesLegacySessionIdentityRecovery().resolve(
            surfaceID: originalSurfaceID,
            corruptSessionID: durableID,
            expectedWorkspaceID: originalWorkspaceID,
            hookStateFileURL: hookStoreURL,
            environment: ["HOME": root.path],
            databaseInspector: { sessionIDs, _, _, _, _ in
                inspectedSessionIDs.append(sessionIDs)
                return HermesAgentIndex.RecoveryInspection(
                    existingSessionIDs: [durableID],
                    evidence: []
                )
            }
        )

        guard case .legacyRestore(let recovered) = resolution else {
            Issue.record("Expected the original pane's durable checkpoint to be re-armed, got \(resolution)")
            return
        }
        #expect(recovered.sessionID == durableID)
        #expect(inspectedSessionIDs == [Set([durableID, transientID])])

        let mismatchedDirectory = HermesLegacySessionIdentityRecovery().resolve(
            surfaceID: originalSurfaceID,
            corruptSessionID: durableID,
            expectedWorkspaceID: originalWorkspaceID,
            expectedWorkingDirectory: root.appendingPathComponent("other-repo").path,
            hookStateFileURL: hookStoreURL,
            environment: ["HOME": root.path],
            databaseInspector: { _, _, _, _, _ in
                HermesAgentIndex.RecoveryInspection(
                    existingSessionIDs: [durableID],
                    evidence: []
                )
            }
        )
        #expect(mismatchedDirectory == .valid)

        let unavailable = HermesLegacySessionIdentityRecovery().resolve(
            surfaceID: originalSurfaceID,
            corruptSessionID: durableID,
            expectedWorkspaceID: originalWorkspaceID,
            expectedWorkingDirectory: root.path,
            hookStateFileURL: hookStoreURL,
            environment: ["HOME": root.path],
            databaseInspector: { _, _, _, _, _ in nil }
        )
        #expect(unavailable == .unavailable)

        let durableSurfaceIdentity = HermesLegacySessionIdentityRecovery().resolve(
            surfaceID: originalSurfaceID,
            corruptSessionID: durableID,
            expectedWorkspaceID: originalWorkspaceID,
            expectedWorkingDirectory: root.path,
            hookStateFileURL: hookStoreURL,
            environment: ["HOME": root.path],
            databaseInspector: { _, _, _, _, _ in
                HermesAgentIndex.RecoveryInspection(
                    existingSessionIDs: [durableID, transientID],
                    evidence: []
                )
            }
        )
        #expect(durableSurfaceIdentity == .valid)
    }

    @Test("Searches messages and scopes sessions by directory")
    func searchesMessagesAndScopesSessionsByDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title, cwd)
        VALUES
          ('session-a', 'cli', 'model-a', 10, 'General', '\(repo.path)'),
          ('session-b', 'cli', 'model-b', 20, 'Other', '\(root.path)');
        INSERT INTO messages (session_id, role, content, timestamp)
        VALUES
          ('session-a', 'assistant', 'Needle text', 11),
          ('session-b', 'assistant', 'Needle text elsewhere', 21);
        """)

        let found = HermesAgentIndex.loadSessions(
            needle: "needle",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )
        let scoped = HermesAgentIndex.loadSessions(
            needle: "needle",
            cwdFilter: repo.path,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )
        let unmatched = HermesAgentIndex.loadSessions(
            needle: "",
            cwdFilter: root.appendingPathComponent("missing").path,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )

        #expect(found.sessions.map(\.sessionId) == ["session-b", "session-a"])
        #expect(scoped.sessions.map(\.sessionId) == ["session-a"])
        #expect(unmatched.sessions.isEmpty)
    }

    @Test("Directory scoping follows Hermes real-path cwd records")
    func directoryScopingMatchesSymlinkedWorkingDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let linkedRepo = root.appendingPathComponent("linked-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedRepo, withDestinationURL: repo)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title, cwd)
        VALUES ('symlink-session', 'cli', 'model-a', 10, 'Linked repo', '\(repo.path)');
        """)

        let scoped = HermesAgentIndex.loadSessions(
            needle: "",
            cwdFilter: linkedRepo.path,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )

        #expect(scoped.sessions.map(\.sessionId) == ["symlink-session"])
    }

    @Test("Unfiltered loading remains compatible with state databases that predate cwd")
    func unfilteredLoadingSupportsLegacySchema() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("legacy-state.db", isDirectory: false)
        try exec(dbURL, """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          source TEXT NOT NULL,
          model TEXT,
          started_at REAL NOT NULL,
          ended_at REAL,
          title TEXT
        );
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT,
          tool_name TEXT,
          tool_calls TEXT,
          timestamp REAL NOT NULL
        );
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('legacy-session', 'cli', 'model-a', 10, 'Legacy');
        """)

        let result = HermesAgentIndex.loadSessions(
            needle: "",
            cwdFilter: nil,
            offset: 0,
            limit: 10,
            stateDBPath: dbURL.path
        )

        #expect(result.errors.isEmpty)
        #expect(result.sessions.map(\.sessionId) == ["legacy-session"])
    }

    @Test("Loads transcript and decodes Hermes JSON content")
    func loadsTranscriptAndDecodesHermesJSONContent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("state.db", isDirectory: false)
        try makeHermesStateDB(at: dbURL)
        try exec(dbURL, """
        INSERT INTO sessions (id, source, model, started_at, title)
        VALUES ('session-a', 'cli', 'model-a', 10, 'General');
        INSERT INTO messages (session_id, role, content, tool_name, tool_calls, timestamp)
        VALUES
          ('session-a', 'user', char(0) || 'json:[{"type":"text","text":"structured hello"}]', NULL, NULL, 11),
          ('session-a', 'tool', 'ran command', 'terminal', '{"command":"pwd"}', 12);
        """)

        let turns = try HermesAgentIndex.loadTranscript(
            sessionId: "session-a",
            limit: 10,
            stateDBPath: dbURL.path
        )

        #expect(turns.count == 2)
        #expect(turns[0].role == "user")
        #expect(turns[0].content == "structured hello")
        #expect(turns[1].toolName == "terminal")
        #expect(turns[1].content.contains("ran command"))
        #expect(turns[1].content.contains("pwd"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-hermes-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeHermesStateDB(at url: URL) throws {
        try exec(url, """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          source TEXT NOT NULL,
          user_id TEXT,
          model TEXT,
          model_config TEXT,
          system_prompt TEXT,
          parent_session_id TEXT,
          started_at REAL NOT NULL,
          ended_at REAL,
          end_reason TEXT,
          message_count INTEGER DEFAULT 0,
          tool_call_count INTEGER DEFAULT 0,
          input_tokens INTEGER DEFAULT 0,
          output_tokens INTEGER DEFAULT 0,
          cache_read_tokens INTEGER DEFAULT 0,
          cache_write_tokens INTEGER DEFAULT 0,
          reasoning_tokens INTEGER DEFAULT 0,
          billing_provider TEXT,
          billing_base_url TEXT,
          billing_mode TEXT,
          estimated_cost_usd REAL,
          actual_cost_usd REAL,
          cost_status TEXT,
          cost_source TEXT,
          pricing_version TEXT,
          cwd TEXT,
          title TEXT,
          api_call_count INTEGER DEFAULT 0
        );
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content TEXT,
          tool_call_id TEXT,
          tool_calls TEXT,
          tool_name TEXT,
          timestamp REAL NOT NULL,
          token_count INTEGER,
          finish_reason TEXT,
          reasoning TEXT,
          reasoning_content TEXT,
          reasoning_details TEXT,
          codex_reasoning_items TEXT,
          codex_message_items TEXT
        );
        """)
    }

    private func exec(_ dbURL: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK, let db else {
            throw HermesAgentIndexError.sqlite("open failed")
        }
        defer { sqlite3_close(db) }

        var error: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        guard result == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw HermesAgentIndexError.sqlite(message)
        }
    }
}
