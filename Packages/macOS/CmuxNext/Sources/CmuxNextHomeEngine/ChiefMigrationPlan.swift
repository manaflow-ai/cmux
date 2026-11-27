import CmuxNextDaemon
import Foundation

/// One old per-tag Chief as its build left it: the Chief conversation of the
/// tag's daemon store, the OptChat memory and the host's cursor.
nonisolated struct ChiefMigrationSource: Sendable, Equatable {
    /// Which messages are human, replies or already logged is cmux-home-rules
    /// `chief_home::migration` (`Message::is_human`, `is_reply`, `Source::is_logged`).
    struct Message: Sendable, Equatable, Codable {
        var id: String
        var seq: UInt64
        var author: String
        var clientMsgID: String
        var createdAt: String
        var parts: [JSONValue]
    }

    /// One OptChat log line.
    struct LogEntry: Sendable, Equatable, Codable {
        var i: Int
        var kind: String
        var text: String
        var date: String
    }

    var name: String
    var muxHome: URL
    var conversationID: String?
    var conversationCreatedAt: String?
    var messages: [Message]
    var log: [LogEntry]
    /// Where `log` was read: the old JSONL memory, or an export of the SQLite one.
    var textDir: URL? = nil
    var loggedSeq: UInt64
    var hostConversation: String?

    /// The rules' `migration::Source`.
    struct Wire: Encodable {
        var name: String
        var conversationID: String?
        var messages: [Message]
        var log: [LogEntry]
        var loggedSeq: UInt64
        var hostConversation: String?
    }

    var wire: Wire {
        Wire(name: name, conversationID: conversationID, messages: messages, log: log, loggedSeq: loggedSeq, hostConversation: hostConversation)
    }
}

/// How the old Chiefs merge into the Chief home (home-state-ownership.md
/// section 7): messages in time order with ids, authors, times and client ids
/// kept, duplicates dropped; the largest memory kept, and every human message
/// no memory holds appended to it, so the chat and the memory hold the same
/// human messages in the same order. The merge is cmux-home-rules
/// `chief_home.migration_plan`.
nonisolated struct ChiefMigrationPlan: Sendable, Equatable {
    enum Memory: Sendable, Equatable {
        /// No source has a memory: the host starts an empty one.
        case none
        /// Copy this source's memory, then append `unlogged`.
        case copy(source: Int)
        /// Several memories: interleave every entry by time (summaries are rebuilt).
        case interleave
    }

    struct Item: Sendable, Equatable {
        var source: Int
        var message: ChiefMigrationSource.Message
    }

    var items: [Item]
    var duplicates: Int
    var memory: Memory
    /// Human messages no memory holds, in the order they are appended to it.
    var unlogged: [Item]
    /// How many unlogged messages moved after the memory's last message.
    var moved: Int

    private struct Request: Encodable { let sources: [ChiefMigrationSource.Wire] }
    private struct Reply: Decodable {
        struct WireItem: Decodable {
            let source: Int
            let message: ChiefMigrationSource.Message
        }
        struct WireMemory: Decodable {
            let kind: String
            let source: Int?
        }
        let items: [WireItem]
        let duplicates: Int
        let memory: WireMemory
        let unlogged: [WireItem]
        let moved: Int
    }

    static func make(_ sources: [ChiefMigrationSource]) throws -> ChiefMigrationPlan {
        let reply: Reply = try ChiefHomeRules().call("migration_plan", Request(sources: sources.map(\.wire)))
        // The sources' own messages, so their parts stay exactly as read.
        let byID = sources.map { source in Dictionary(source.messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        func item(_ wire: Reply.WireItem) -> Item {
            let own = byID.indices.contains(wire.source) ? byID[wire.source][wire.message.id] : nil
            return Item(source: wire.source, message: own ?? wire.message)
        }
        let memory: Memory = switch (reply.memory.kind, reply.memory.source) {
        case ("copy", let source?): .copy(source: source)
        case ("interleave", _): .interleave
        default: .none
        }
        return ChiefMigrationPlan(items: reply.items.map(item), duplicates: reply.duplicates, memory: memory,
                                  unlogged: reply.unlogged.map(item), moved: reply.moved)
    }

    /// What the owner imports, in order.
    var imports: [ConversationImportedMessage] {
        items.map { item in
            ConversationImportedMessage(id: item.message.id, clientMsgID: item.message.clientMsgID, author: item.message.author,
                                        parts: item.message.parts, createdAt: item.message.createdAt)
        }
    }
}
