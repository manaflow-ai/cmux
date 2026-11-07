public import CmuxHomeCore
public import CmuxNextSettings
import Foundation

/// The Messages page's unsent sends across launches (`cmux.home.messages.outbox.*`), in HomeStore's
/// draft cache beside its drafts, as the native composer's durable outbox kept them: a send the
/// owner has not shown yet comes back after a relaunch as not sent, with Retry (its idempotency key
/// kept, so it never goes twice). The page owns the rows; this keeps their JSON per conversation.
@MainActor
public struct HomeMessagesOutbox {
    /// The most rows and text kept per conversation (a runaway page cannot fill the cache).
    public static let maxRows = 200
    public static let maxBytes = 1_000_000

    private let store: HomeStore

    public init(store: HomeStore) {
        self.store = store
    }

    /// `{pending: {id: [row]}}`.
    public func load() -> JSONValue {
        var out: [String: JSONValue] = [:]
        for id in store.pendingWebSendConversations {
            guard let text = store.pendingWebSends(for: id), let rows = try? JSONValue.parse(Data(text.utf8)),
                  case .array(let list) = rows, !list.isEmpty else { continue }
            out[id.rawValue] = rows
        }
        return .object(["pending": .object(out)])
    }

    /// Keeps `rows` (oldest first; none clears them) as `id`'s unsent sends. Throws past the caps.
    public func save(_ rows: [JSONValue], for id: ConversationID) throws {
        guard rows.count <= Self.maxRows else { throw Refusal.tooMany }
        let text = rows.isEmpty ? nil : JSONValue.array(rows).compactText
        guard (text?.utf8.count ?? 0) <= Self.maxBytes else { throw Refusal.tooLarge }
        store.setPendingWebSends(text, for: id)
    }

    public enum Refusal: Error {
        case tooMany, tooLarge
    }
}
