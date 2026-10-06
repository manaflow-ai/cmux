import CmuxNextDaemon
import Foundation
import SQLite3
import Testing
@testable import CmuxNextApp

/// The app moves the old per-tag Chiefs into the Chief home itself, once
/// (home-state-ownership.md section 7): the owner imports the history with
/// its own authors and times, the memory gets every human message no memory
/// held, and a running old host blocks the move until a later launch. Shaped
/// like Lawrence's 2026-10-05 data: hmchief (a notice), hmchief3 (history and
/// a memory), hmchief4 (one message no host logged).
@Suite struct ChiefMigrationTests {
    final class FakeOwner: ChiefMigrationOwner, @unchecked Sendable {
        var imports: [ConversationImportRequest] = []
        let lock = NSLock()

        func chiefConversation() async throws -> String { "conv_chief" }

        func importHistory(_ request: ConversationImportRequest) async throws -> ConversationImportResult {
            lock.withLock { imports.append(request) }
            let summary = ConversationSummary(id: "conv_chief", title: "Chief", participants: [], lastSeq: UInt64(request.messages.count),
                                              rev: 2, createdAt: "2026-10-06T00:00:00.000Z", updatedAt: "2026-10-06T00:00:00.000Z")
            return ConversationImportResult(conversation: summary, imported: Array(1...UInt64(max(request.messages.count, 1))), skipped: 0)
        }
    }

    static func temp() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chief-migration-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One old tag: its store (the daemon's schema, the columns read here),
    /// its memory and its host state.
    static func tag(_ root: URL, _ name: String, conversation: String, created: String,
                    messages: [(String, String, String, String, String)], log: [(String, String, String)] = [],
                    loggedSeq: UInt64? = nil) -> ChiefMigration.Old {
        let mux = root.appendingPathComponent("mux/\(name)", isDirectory: true)
        let main = mux.appendingPathComponent("optchat/chat/main", isDirectory: true)
        try? FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: mux.appendingPathComponent("optchat/chat/tree"), withIntermediateDirectories: true)
        for (index, entry) in log.enumerated() {
            let line = ChiefMigrationPlan.logLine(i: index, kind: entry.0, text: entry.1, date: entry.2)
            let file = main.appendingPathComponent(String(entry.2.prefix(10)) + ".jsonl")
            let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            try? (old + line).write(to: file, atomically: true, encoding: .utf8)
        }
        if let loggedSeq {
            try? Data(#"{"conversation":"\#(conversation)","logged_seq":\#(loggedSeq),"outbox":[],"turn":null,"children":{}}"#.utf8)
                .write(to: mux.appendingPathComponent("optchat/host.json"))
        }
        let store = root.appendingPathComponent("tui/\(name)/conversations.sqlite3")
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        sqlite3_open(store.path, &db)
        sqlite3_exec(db, "CREATE TABLE conversation (id TEXT PRIMARY KEY, title TEXT, participants_json TEXT, last_seq INTEGER, rev INTEGER, created_at TEXT, updated_at TEXT); CREATE TABLE message (conversation TEXT, seq INTEGER, id TEXT, message_json TEXT);", nil, nil, nil)
        let participants = #"[{"id":"user_local","kind":"human"},{"id":"agent_mux","kind":"agent"}]"#
        sqlite3_exec(db, "INSERT INTO conversation VALUES ('\(conversation)', 'Chief', '\(participants)', \(messages.count), 1, '\(created)', '\(created)')", nil, nil, nil)
        for (index, m) in messages.enumerated() {
            let json = #"{"id":"\#(m.0)","conversation":"\#(conversation)","seq":\#(index + 1),"client_msg_id":"\#(m.2)","author":"\#(m.1)","parts":[{"type":"text","text":"\#(m.3)"}],"created_at":"\#(m.4)","reactions":[]}"#
            sqlite3_exec(db, "INSERT INTO message VALUES ('\(conversation)', \(index + 1), '\(m.0)', '\(json)')", nil, nil, nil)
        }
        sqlite3_close(db)
        return ChiefMigration.Old(tag: name, muxHome: mux, store: store)
    }

    static func lawrenceLike(_ root: URL) -> [ChiefMigration.Old] {
        [
            tag(root, "hmchief", conversation: "conv_A", created: "2026-10-06T00:29:27.642Z",
                messages: [("msg_a1", "agent_mux", "notice:optchat:compactor:1", "The compactor cannot build summaries", "2026-10-06T00:29:27.800Z")],
                loggedSeq: 1),
            tag(root, "hmchief3", conversation: "conv_B", created: "2026-10-06T03:05:53.696Z", messages: [
                ("msg_b1", "user_local", "cmk_1", "hi", "2026-10-06T03:06:01.998Z"),
                ("msg_b2", "agent_mux", "turn:optchat:0:x", "Hello.", "2026-10-06T03:06:04.622Z"),
            ], log: [("user", "hi", "2026-10-05T20:06:02.025-07:00"), ("talk", "Hello.", "2026-10-05T20:06:04.279-07:00")], loggedSeq: 2),
            tag(root, "hmchief4", conversation: "conv_C", created: "2026-10-06T04:49:46.626Z",
                messages: [("msg_c1", "user_local", "cmk_3", "What are my agents doing right now?", "2026-10-06T04:55:30.495Z")]),
        ]
    }

    static func userEntries(_ home: ChiefHome) -> [String] {
        ChiefMigration.readLog(home.root.appendingPathComponent("optchat/chat/main")).filter { $0.kind == "user" }.map(\.text)
    }

    @Test func theOldChiefsMoveOnceInTimeOrderAndTheMemoryHoldsTheSameHumanMessages() async throws {
        let root = Self.temp()
        let olds = Self.lawrenceLike(root)
        let home = ChiefHome(root: root.appendingPathComponent("chief/default", isDirectory: true), isolated: false)
        let owner = FakeOwner()
        let outcome = try await ChiefMigration.run(home: home, owner: owner, olds: olds)
        #expect(outcome == .done(messages: 4, memoryEntries: 3))
        let sent = try #require(owner.imports.first)
        #expect(sent.conversation == "conv_chief")
        #expect(sent.messages.map(\.id) == ["msg_a1", "msg_b1", "msg_b2", "msg_c1"])
        #expect(sent.messages.map(\.createdAt).first == "2026-10-06T00:29:27.800Z", "the owner gets the original times")
        #expect(Self.userEntries(home) == ["hi", "What are my agents doing right now?"])
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: home.root.appendingPathComponent("optchat/host.json"))) as? [String: Any]
        #expect(state?["conversation"] as? String == "conv_chief")
        #expect((state?["logged_seq"] as? NSNumber)?.intValue == 4, "every imported message is logged: no turn answers old history")
        #expect(FileManager.default.fileExists(atPath: home.root.appendingPathComponent(ChiefMigration.recordName).path))
        // The old homes and stores were only read.
        #expect(FileManager.default.fileExists(atPath: olds[1].store.path))
        #expect(ChiefMigration.readLog(olds[1].muxHome.appendingPathComponent("optchat/chat/main")).count == 2)
        // A second launch moves nothing.
        #expect(try await ChiefMigration.run(home: home, owner: owner, olds: olds) == .nothingToDo)
        #expect(owner.imports.count == 1)
    }

    @Test func aRunningOldHostBlocksTheMoveUntilALaterLaunch() async throws {
        let root = Self.temp()
        let olds = Self.lawrenceLike(root)
        let lockFile = olds[1].muxHome.appendingPathComponent("state/host.lock")
        try FileManager.default.createDirectory(at: lockFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let held = try #require(ChiefMigration.HostLock(path: lockFile), "the old hmchief3 host runs")
        let home = ChiefHome(root: root.appendingPathComponent("chief/default", isDirectory: true), isolated: false)
        let owner = FakeOwner()
        #expect(try await ChiefMigration.run(home: home, owner: owner, olds: olds) == .blocked(["hmchief3"]))
        #expect(owner.imports.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.root.appendingPathComponent(ChiefMigration.recordName).path))
        held.release()
        #expect(try await ChiefMigration.run(home: home, owner: owner, olds: olds) == .done(messages: 4, memoryEntries: 3))
    }

    @Test func anIsolatedHomeNeverTakesTheUsersChiefs() async throws {
        let root = Self.temp()
        let home = ChiefHome(root: root.appendingPathComponent("chief/isolated/pf1", isDirectory: true), isolated: true)
        let owner = FakeOwner()
        #expect(try await ChiefMigration.run(home: home, owner: owner, olds: Self.lawrenceLike(root)) == .nothingToDo)
        #expect(owner.imports.isEmpty)
    }

    @Test func theTagStorePathIsTheDaemonsOwn() {
        #expect(ChiefMigration.sessionComponent("cmux-app-hmchief") == "cmux-app-hmchief-de68d63ca74ae6ff")
        let olds = ChiefMigration.oldChiefs(userHome: URL(fileURLWithPath: "/nonexistent"), applicationSupport: URL(fileURLWithPath: "/x"))
        #expect(olds.isEmpty)
    }
}

/// The SQLite memory store (feat-cmux-next d489934e0a53): an old Chief whose
/// memory is `memory.sqlite3` is read through `memory export --text`, never
/// its database file, and the Chief home's memory is written through
/// `memory import`.
@Suite struct ChiefMigrationStoreTests {
    final class FakeTool: ChiefMemoryTool, @unchecked Sendable {
        let exports: [String: URL]
        var imported: [URL] = []
        var exported: [URL] = []
        let lock = NSLock()
        init(exports: [String: URL]) { self.exports = exports }

        func exportText(muxHome: URL, to directory: URL) throws {
            lock.withLock { exported.append(muxHome) }
            try FileManager.default.copyItem(at: try #require(exports[muxHome.lastPathComponent]), to: directory)
        }

        func importText(muxHome: URL, from directory: URL) throws {
            lock.withLock { imported.append(directory) }
            let chat = muxHome.appendingPathComponent("optchat/chat", isDirectory: true)
            try FileManager.default.createDirectory(at: chat.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: directory, to: chat)
            FileManager.default.createFile(atPath: muxHome.appendingPathComponent("optchat/memory.sqlite3").path, contents: Data())
        }
    }

    @Test func aSQLiteMemoryIsReadThroughItsExportAndTheHomeIsWrittenThroughImport() async throws {
        let root = ChiefMigrationTests.temp()
        var olds = ChiefMigrationTests.lawrenceLike(root)
        // hmchief3 ran the SQLite store: its day files moved into the database.
        let three = olds[1].muxHome
        let export = root.appendingPathComponent("export-fixture", isDirectory: true)
        try FileManager.default.moveItem(at: three.appendingPathComponent("optchat/chat"), to: export)
        try FileManager.default.removeItem(at: three.appendingPathComponent("optchat/host.json"))
        var db: OpaquePointer?
        sqlite3_open(three.appendingPathComponent("optchat/memory.sqlite3").path, &db)
        sqlite3_exec(db, #"CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL); INSERT INTO state VALUES ('host/conversation', '"conv_B"'), ('host/logged_seq', '2');"#, nil, nil, nil)
        sqlite3_close(db)
        olds[1] = ChiefMigration.Old(tag: olds[1].tag, muxHome: three, store: olds[1].store)
        let tool = FakeTool(exports: ["hmchief3": export])
        let home = ChiefHome(root: root.appendingPathComponent("chief/default", isDirectory: true), isolated: false)
        let owner = ChiefMigrationTests.FakeOwner()
        let outcome = try await ChiefMigration.run(home: home, owner: owner, olds: olds, tool: tool)
        #expect(outcome == .done(messages: 4, memoryEntries: 3))
        #expect(tool.exported.map(\.lastPathComponent) == ["hmchief3"], "only the SQLite memory goes through export")
        #expect(tool.imported.count == 1, "the Chief home's memory is written through the store's import")
        #expect(ChiefMigrationTests.userEntries(home) == ["hi", "What are my agents doing right now?"],
                "hmchief3's logged 'hi' is not appended twice: its cursor came from the store's state")
    }
}
