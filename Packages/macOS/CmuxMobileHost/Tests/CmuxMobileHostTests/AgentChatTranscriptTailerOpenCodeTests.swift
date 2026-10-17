@testable import CmuxMobileHost
import Foundation
import SQLite3
import Testing

struct AgentChatTranscriptTailerOpenCodeTests {
    private func nextBatch(
        from stream: AsyncStream<AgentChatTranscriptTailer.Batch>,
        within timeout: Duration = .seconds(5)
    ) async -> AgentChatTranscriptTailer.Batch? {
        await withTaskGroup(of: AgentChatTranscriptTailer.Batch?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test func readsOpenCodeSQLiteMessagesAndToolState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-opencode-tailer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("opencode.db")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        guard let database else { return }
        defer { sqlite3_close(database) }
        let schema = """
            CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, time_updated INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT, time_created INTEGER);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, data TEXT, time_created INTEGER);
            INSERT INTO session VALUES ('ses_test', '/tmp/project', 2);
            INSERT INTO message VALUES ('m_user', 'ses_test', '{\"role\":\"user\"}', 1);
            INSERT INTO part VALUES ('p_user', 'm_user', '{\"type\":\"text\",\"text\":\"inspect this\"}', 1);
            INSERT INTO message VALUES ('m_agent', 'ses_test', '{\"role\":\"assistant\"}', 2);
            INSERT INTO part VALUES ('p_tool', 'm_agent', '{\"type\":\"tool\",\"tool\":\"bash\",\"state\":{\"status\":\"completed\",\"input\":{\"command\":\"pwd\"},\"output\":\"/tmp/project\"}}', 2);
            """
        var error: UnsafeMutablePointer<CChar>?
        #expect(sqlite3_exec(database, schema, nil, nil, &error) == SQLITE_OK)
        sqlite3_free(error)

        let tailer = AgentChatTranscriptTailer(
            sessionID: "ses_test",
            agentKind: .other("opencode"),
            path: databaseURL.path,
            onBatch: { _ in }
        )
        await tailer.start()
        let page = await tailer.history(beforeSeq: nil, limit: 20)
        await tailer.stop()

        #expect(page.messages.count == 2)
        #expect(page.messages[0].role == .user)
        if case .prose(let prose) = page.messages[0].kind {
            #expect(prose.text == "inspect this")
        } else {
            Issue.record("expected OpenCode text part to become prose")
        }
        if case .terminal(let terminal) = page.messages[1].kind {
            #expect(terminal.command == "pwd")
            #expect(terminal.output == "/tmp/project")
            #expect(!terminal.isRunning)
        } else {
            Issue.record("expected OpenCode bash tool to become a terminal card")
        }
    }

    @Test func tailsToolUpdatesAndMultiFilePatchesFromSQLite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-opencode-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("opencode.db")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        guard let database else { return }
        defer { sqlite3_close(database) }
        let schema = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, time_updated INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT, time_created INTEGER);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, data TEXT, time_created INTEGER);
            INSERT INTO session VALUES ('ses_live', '/tmp/project', 2);
            INSERT INTO message VALUES ('m_user', 'ses_live', '{"role":"user"}', 1);
            INSERT INTO part VALUES ('p_user', 'm_user', '{"type":"text","text":"make the change"}', 1);
            INSERT INTO message VALUES ('m_agent', 'ses_live', '{"role":"assistant"}', 2);
            INSERT INTO part VALUES ('p_tool', 'm_agent', '{"type":"tool","tool":"bash","state":{"status":"running","input":{"command":"pwd"}}}', 2);
            """
        #expect(sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK)

        let (stream, continuation) = AsyncStream<AgentChatTranscriptTailer.Batch>.makeStream()
        let tailer = AgentChatTranscriptTailer(
            sessionID: "opencode:ses_live",
            agentKind: .other("opencode"),
            path: databaseURL.path,
            maxCachedMessages: 3,
            onBatch: { batch in continuation.yield(batch) }
        )
        await tailer.start()
        let initial = await tailer.history(beforeSeq: nil, limit: 20)
        #expect(initial.messages.count == 2)
        #expect(initial.hasMore == false)

        let updateSQL = """
            UPDATE part SET data='{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"pwd"},"output":"/tmp/project"}}' WHERE id='p_tool';
            INSERT INTO part VALUES ('p_patch', 'm_agent', '{"type":"patch","files":[{"path":"Sources/App.swift","diff":"@@\\n-old\\n+new\\n","operation":"edit"},{"path":"Tests/AppTests.swift","diff":"@@\\n+test\\n","operation":"write"}]}', 3);
            """
        #expect(sqlite3_exec(database, updateSQL, nil, nil, nil) == SQLITE_OK)
        let batch = await nextBatch(from: stream)
        continuation.finish()
        await tailer.stop()

        let received = try #require(batch)
        #expect(received.updated.contains { message in
            guard case .terminal(let terminal) = message.kind else { return false }
            return terminal.output == "/tmp/project" && !terminal.isRunning
        })
        #expect(received.appended.count == 2)
        #expect(received.appended.allSatisfy { message in
            if case .fileEdit = message.kind { return true }
            return false
        })
        let history = await tailer.history(beforeSeq: nil, limit: 20)
        #expect(history.messages.count == 3)
        #expect(history.hasMore == true)
    }
}
