public import CmuxHomeCore
public import CmuxNextSettings
import Foundation

/// The Messages page's unsent sends across launches (`cmux.home.messages.outbox.*`), in HomeStore's
/// draft cache beside its drafts, as the native composer's durable outbox kept them: a send the
/// owner has not shown yet comes back after a relaunch as not sent, with Retry (its idempotency key
/// kept, so it never goes twice). Each send is its own entry, by its key: a page adds or removes one
/// send, so two pages showing one conversation never overwrite each other's. HomeStore's own Not
/// Delivered sends (the native composer's, from before the page; a send the host made for the
/// page) move into it as the page loads it (``adoptStoreSends()``), so they show with Retry too.
@MainActor
public struct HomeMessagesOutbox {
    /// The largest send kept (a paste of a log still goes; a runaway page cannot fill the cache).
    public static let maxEntryBytes = 8_000_000

    private let store: HomeStore

    public init(store: HomeStore) {
        self.store = store
    }

    /// `{pending: {id: [row]}}`, each conversation's rows oldest first (HomeStore's own failed sends among them).
    public func load() -> JSONValue {
        adoptStoreSends()
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

    /// Lets go of one send (delivered, or discarded); returns the hashes of the files it named,
    /// whose kept bytes it owned (``HomeMessagesAttachmentDrafts/releaseBytes(_:)``).
    @discardableResult
    public func remove(_ key: String, for id: ConversationID) -> [String] {
        let row = store.pendingWebSends(for: id)[key]
        store.setPendingWebSend(nil, key: key, for: id)
        return row.flatMap { try? JSONValue.parse(Data($0.utf8)) }.map(Self.hashes) ?? []
    }

    /// The hashes of the files the kept sends name (their bytes stay while one does).
    public func attachmentHashes() -> Set<String> {
        var out: Set<String> = []
        for id in store.pendingWebSendConversations {
            for text in store.pendingWebSends(for: id).values {
                guard let row = try? JSONValue.parse(Data(text.utf8)) else { continue }
                out.formUnion(Self.hashes(row))
            }
        }
        return out
    }

    static func hashes(_ row: JSONValue) -> [String] {
        (row.value(at: ["attachments"])?.arrayValue ?? []).compactMap { $0.value(at: ["hash"])?.stringValue }
    }

    /// HomeStore's Not Delivered text sends leave its log for this outbox, each under its key: the
    /// page shows them as not sent, with Retry, and never both pages' copies. One this outbox refuses
    /// (past ``maxEntryBytes``) stays in the log, so it is never lost.
    public func adoptStoreSends() {
        store.handOverFailedTextSends { send in (try? put(Self.row(send), for: send.conversation)) != nil }
    }

    /// A HomeStore send as the page keeps one (outbox.ts `PendingSend`): its key, text and thread, not sent.
    public static func row(_ send: HomeCachedSend) -> JSONValue {
        var fields: [String: JSONValue] = [
            "key": .string(send.key.rawValue), "conversation": .string(send.conversation.rawValue),
            "text": .string(send.parts.map(\.plainText).joined(separator: "\n")),
            "createdAt": .number((send.issuedAt.timeIntervalSince1970 * 1000).rounded()), "failed": .bool(true),
        ]
        if let root = send.threadRoot { fields["threadRoot"] = .string(root.rawValue) }
        if let parent = send.parent { fields["replyTo"] = .string(parent.rawValue) }
        return .object(fields)
    }

    public enum Refusal: Error {
        case noKey, tooLarge
    }
}
