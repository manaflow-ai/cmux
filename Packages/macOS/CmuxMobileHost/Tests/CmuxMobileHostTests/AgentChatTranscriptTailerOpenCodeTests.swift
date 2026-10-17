import CmuxAgentChat
import CmuxMobileHost
import Foundation
import SQLite3
import Testing

struct AgentChatTranscriptTailerOpenCodeTests {
    @Test func readsOpenCodeSQLiteMessagesAndToolState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-opencode-tailer-(UUID().uuidString)", isDirectory: true)
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
}
