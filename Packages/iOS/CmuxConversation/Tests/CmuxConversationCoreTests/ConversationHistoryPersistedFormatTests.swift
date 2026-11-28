import Foundation
import SQLite3
import Testing
@testable import CmuxConversationCore

/// Loads every persisted-formats/conversation-history-database/v*.json fixture through the real
/// ConversationHistoryDatabase, as this build and as a stand-in for a newer build's file
/// (persisted-formats/README-ios-formats.md).
@Suite struct ConversationHistoryPersistedFormatTests {
    struct Fixture: Decodable {
        var userVersion: Int32
        var sql: [String]
        var newerBuildSQL: [String]
        var conversation: String
        var messages: [ExpectedMessage]
        var title: String
        var meID: String
        var participants: Int
        var pinned: Bool
        var range: ExpectedRange
        var deletedID: String

        enum CodingKeys: String, CodingKey {
            case userVersion = "user_version"
            case sql
            case newerBuildSQL = "newer_build_sql"
            case conversation, messages, title, meID, participants, pinned, range, deletedID
        }
    }

    struct ExpectedMessage: Decodable {
        var id: String
        var seq: Int
        var senderID: String
        var text: String
        var reactions: Int
    }

    struct ExpectedRange: Decodable {
        var oldestSeq: Int
        var newestSeq: Int
        var complete: Bool
    }

    @Test func conversationHistoryFixturesLoad() throws {
        let directory = try Self.fixtureDirectory()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("v") && $0.hasSuffix(".json") }
            .sorted()
        #expect(files.contains("v\(ConversationHistoryDatabase.schemaVersion).json"))
        for file in files {
            let fixture = try JSONDecoder().decode(
                Fixture.self, from: Data(contentsOf: directory.appendingPathComponent(file))
            )
            try check(fixture, file: file, asNewerBuild: false)
            if !fixture.newerBuildSQL.isEmpty {
                try check(fixture, file: file, asNewerBuild: true)
            }
        }
    }

    private func check(_ fixture: Fixture, file: String, asNewerBuild: Bool) throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let url = scratch.appendingPathComponent("history.sqlite")
        let newerVersion = max(fixture.userVersion, ConversationHistoryDatabase.schemaVersion) + 1
        var statements = fixture.sql + ["PRAGMA user_version = \(fixture.userVersion)"]
        if asNewerBuild {
            statements += fixture.newerBuildSQL + ["PRAGMA user_version = \(newerVersion)"]
        }
        try Self.run(statements, at: url)

        let label = "\(file)\(asNewerBuild ? " (newer build)" : "")"
        let conversation = fixture.conversation
        do {
            let database = try ConversationHistoryDatabase(url: url)
            let messages = try database.newest(conversation, limit: 100)
            #expect(messages.map(\.id) == fixture.messages.map(\.id), "\(label): messages")
            for (message, want) in zip(messages, fixture.messages) {
                #expect(message.seq == want.seq, "\(label) \(want.id): seq")
                #expect(message.senderID == want.senderID, "\(label) \(want.id): senderID")
                #expect(message.text == want.text, "\(label) \(want.id): text")
                #expect(message.reactions.count == want.reactions, "\(label) \(want.id): reactions")
            }
            #expect(try database.count(conversation) == fixture.messages.count, "\(label): count")
            let stored = try #require(try database.info(conversation), "\(label): conversation row")
            let info = try #require(stored.info, "\(label): info decodes")
            #expect(info.title == fixture.title, "\(label): title")
            #expect(info.participants.count == fixture.participants, "\(label): participants")
            #expect(info.listState.pinned == fixture.pinned, "\(label): pinned")
            #expect(stored.meID == fixture.meID, "\(label): meID")
            #expect(try database.syncedRange(conversation) == ConversationHistoryRange(
                oldestSeq: fixture.range.oldestSeq, newestSeq: fixture.range.newestSeq, complete: fixture.range.complete
            ), "\(label): range")
            #expect(try database.conversations() == [conversation], "\(label): conversations")

            // A message deleted for me stays deleted when a sync brings it again.
            var again = try #require(messages.last)
            again.id = fixture.deletedID
            again.seq = (again.seq ?? 0) + 1
            try database.write(conversation, messages: [again])
            #expect(try database.count(conversation) == fixture.messages.count, "\(label): deleted stays deleted")
        }
        let expectedVersion = asNewerBuild ? newerVersion : ConversationHistoryDatabase.schemaVersion
        #expect(try Self.userVersion(at: url) == expectedVersion, "\(label): user_version")
    }

    /// The repo's persisted-formats/conversation-history-database, found from this file's path.
    static func fixtureDirectory(filePath: String = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let formats = directory.appendingPathComponent("persisted-formats")
            if FileManager.default.fileExists(atPath: formats.appendingPathComponent("formats.toml").path) {
                return formats.appendingPathComponent("conversation-history-database")
            }
            directory = directory.deletingLastPathComponent()
        }
        throw FixtureError.notFound(filePath)
    }

    enum FixtureError: Error {
        case notFound(String)
        case sqlite(String)
    }

    private static func withDatabase<T>(at url: URL, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw FixtureError.sqlite("open \(url.path)")
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private static func run(_ statements: [String], at url: URL) throws {
        try withDatabase(at: url) { database in
            for statement in statements {
                guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
                    throw FixtureError.sqlite("\(String(cString: sqlite3_errmsg(database))): \(statement)")
                }
            }
        }
    }

    private static func userVersion(at url: URL) throws -> Int32 {
        try withDatabase(at: url) { database in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else {
                throw FixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            return sqlite3_column_int(statement, 0)
        }
    }
}
