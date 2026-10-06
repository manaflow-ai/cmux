import CmuxNextDaemon
import Foundation

/// One old per-tag Chief as its build left it: the Chief conversation of the
/// tag's daemon store, the OptChat memory and the host's cursor.
nonisolated struct ChiefMigrationSource: Sendable, Equatable {
    struct Message: Sendable, Equatable {
        var id: String
        var seq: UInt64
        var author: String
        var clientMsgID: String
        var createdAt: String
        var parts: [JSONValue]

        var isHuman: Bool { author.hasPrefix("user_") }
        var isReply: Bool { clientMsgID.hasPrefix("turn:") }
        var text: String {
            parts.compactMap { part -> String? in
                guard case .object(let fields) = part, fields["type"] == .string("text"), case .string(let text)? = fields["text"] else { return nil }
                return text
            }.joined(separator: "\n")
        }
    }

    /// One OptChat log line.
    struct LogEntry: Sendable, Equatable {
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
    var loggedSeq: UInt64
    var hostConversation: String?

    /// A human message this tag's host logged into its memory.
    func isLogged(_ message: Message) -> Bool {
        message.isHuman && hostConversation != nil && hostConversation == conversationID && message.seq <= loggedSeq
    }
}

/// How the old Chiefs merge into the Chief home (home-state-ownership.md
/// section 7): messages in time order with ids, authors, times and client ids
/// kept, duplicates dropped; the largest memory kept, and every human message
/// no memory holds appended to it, so the chat and the memory hold the same
/// human messages in the same order.
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

    static func make(_ sources: [ChiefMigrationSource]) -> ChiefMigrationPlan {
        var seenIDs = Set<String>()
        var seenKeys = Set<String>()
        var duplicates = 0
        var items: [Item] = []
        let ordered = sources.enumerated().flatMap { index, source in source.messages.map { Item(source: index, message: $0) } }
            .sorted { a, b in
                (time(a.message.createdAt), a.source, a.message.seq) < (time(b.message.createdAt), b.source, b.message.seq)
            }
        for item in ordered {
            let key = item.message.author + "\u{0}" + item.message.clientMsgID
            if seenIDs.contains(item.message.id) || seenKeys.contains(key) {
                duplicates += 1
                continue
            }
            seenIDs.insert(item.message.id)
            seenKeys.insert(key)
            items.append(item)
        }
        let withMemory = sources.indices.filter { !sources[$0].log.isEmpty }
        let memory: Memory = switch withMemory.count {
        case 0: .none
        case 1: .copy(source: withMemory[0])
        default: .interleave
        }
        func inMemory(_ item: Item) -> Bool {
            switch memory {
            case .none: false
            case .copy(let source): item.source == source && sources[source].isLogged(item.message)
            case .interleave: sources[item.source].isLogged(item.message)
            }
        }
        var moved = 0
        if case .copy(let base) = memory {
            // Memory order wins: an unlogged human message dated before the
            // memory's last message moves after it (keeping its own order).
            let held = items.filter { $0.source == base && (($0.message.isHuman && inMemory($0)) || $0.message.isReply) }
            if let last = held.map({ time($0.message.createdAt) }).max() {
                let late = Set(items.filter { $0.message.isHuman && !inMemory($0) && time($0.message.createdAt) < last }.map(\.message.id))
                moved = late.count
                if moved > 0 {
                    let kept = items.filter { !late.contains($0.message.id) }
                    let lateItems = items.filter { late.contains($0.message.id) }
                    let cut = kept.lastIndex { time($0.message.createdAt) <= last }.map { $0 + 1 } ?? 0
                    items = Array(kept[..<cut]) + lateItems + Array(kept[cut...])
                }
            }
        }
        let unlogged = items.filter { $0.message.isHuman && !inMemory($0) }
        return ChiefMigrationPlan(items: items, duplicates: duplicates, memory: memory, unlogged: unlogged, moved: moved)
    }

    /// Seconds since 1970 of an RFC 3339 time (UTC `Z` or an offset), else 0.
    static func time(_ text: String) -> Double {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)?.timeIntervalSince1970 ?? 0
    }

    /// What the owner imports, in order.
    var imports: [ConversationImportedMessage] {
        items.map { item in
            ConversationImportedMessage(id: item.message.id, clientMsgID: item.message.clientMsgID, author: item.message.author,
                                        parts: item.message.parts, createdAt: item.message.createdAt)
        }
    }

    /// An OptChat log line (optchat-host lines.rs `main_line`).
    static func logLine(i: Int, kind: String, text: String, date: String) -> String {
        let object: [String: Any] = ["i": i, "kind": kind, "text": text, "size": kind.utf8.count + 2 + text.utf8.count, "date": date]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// A stored owner time as the log's local time with offset.
    static func localDate(_ text: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter.string(from: Date(timeIntervalSince1970: time(text)))
    }
}
