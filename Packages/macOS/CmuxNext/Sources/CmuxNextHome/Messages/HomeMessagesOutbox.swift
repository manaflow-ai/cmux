public import CmuxHomeCore
public import CmuxNextSettings
import Foundation

/// The Messages page's unsent sends across launches (`cmux.home.messages.outbox.*`), in HomeStore's
/// draft cache beside its drafts, as the native composer's durable outbox kept them: a send the
/// owner has not shown yet comes back after a relaunch as not sent, with Retry (its idempotency key
/// kept, so it never goes twice). Each send is its own entry, by its key: a page adds or removes one
/// send, so two pages showing one conversation never overwrite each other's.
@MainActor
public struct HomeMessagesOutbox {
    /// The largest send kept (a paste of a log still goes; a runaway page cannot fill the cache).
    public static let maxEntryBytes = 8_000_000

    private let store: HomeStore

    public init(store: HomeStore) {
        self.store = store
    }

    /// `{pending: {id: [row]}}`, each conversation's rows oldest first.
    public func load() -> JSONValue {
        var out: [String: JSONValue] = [:]
        for id in store.pendingWebSendConversations {
            let rows = store.pendingWebSends(for: id).values.compactMap { try? JSONValue.parse(Data($0.utf8)) }
                .sorted { ($0.value(at: ["createdAt"])?.doubleValue ?? 0) < ($1.value(at: ["createdAt"])?.doubleValue ?? 0) }
            if !rows.isEmpty { out[id.rawValue] = .array(rows) }
        }
        return .object(["pending": .object(out)])
    }

    /// Keeps one send (`row`, keyed by its `key`) as `id`'s. Throws for a row with no key or past
    /// ``maxEntryBytes``: the page then tells the person it is not kept.
    public func put(_ row: JSONValue, for id: ConversationID) throws {
        guard let key = row.value(at: ["key"])?.stringValue, !key.isEmpty else { throw Refusal.noKey }
        let text = row.compactText
        guard text.utf8.count <= Self.maxEntryBytes else { throw Refusal.tooLarge }
        store.setPendingWebSend(text, key: key, for: id)
    }

    /// Lets go of one send (delivered, or discarded).
    public func remove(_ key: String, for id: ConversationID) {
        store.setPendingWebSend(nil, key: key, for: id)
    }

    public enum Refusal: Error {
        case noKey, tooLarge
    }
}
