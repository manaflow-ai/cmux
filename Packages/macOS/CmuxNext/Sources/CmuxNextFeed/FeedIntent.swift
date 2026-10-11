public import Foundation

/// A typed user intent the client sends to the feed owner. Until its echo
/// (an event that carries the intent's key as `tx`) or its settle arrives,
/// the client shows the intent applied on top of the confirmed mirror; no
/// other optimistic copy exists (OWNERSHIP-PRINCIPLES "Clients are
/// projections").
public nonisolated enum FeedIntentKind: Sendable, Equatable {
    case answer(item: String, value: FeedAnswerValue)
    /// `feed.cancel` with reason `declined`.
    case decline(item: String)
    case read(items: [String])
    case archive(items: [String])
    case snooze(items: [String], until: Date)
    /// Reads every unread item posted at or before `before`.
    case markAllRead(before: Date)
}

public nonisolated struct FeedIntent: Sendable, Equatable, Identifiable {
    /// The idempotency key; the echo carries it as `tx`.
    public let key: String
    public let kind: FeedIntentKind
    /// When the user acted (the overlay's answer and triage times).
    public let at: Date
    public var id: String { key }

    public init(key: String = "idem_" + UUID().uuidString.lowercased(), kind: FeedIntentKind, at: Date) {
        self.key = key
        self.kind = kind
        self.at = at
    }

    /// The catalog op (feed.md section 6).
    public var op: String {
        switch kind {
        case .answer: "feed.answer"
        case .decline: "feed.cancel"
        case .read, .markAllRead: "feed.read"
        case .archive: "feed.archive"
        case .snooze: "feed.snooze"
        }
    }

    /// The items this intent touches (nil: every item, `markAllRead`).
    public var items: [String]? {
        switch kind {
        case let .answer(item, _), let .decline(item): [item]
        case let .read(items), let .archive(items), let .snooze(items, _): items
        case .markAllRead: nil
        }
    }

    /// The visible effect of this intent on a mirror (pure). Mirrors the
    /// owner's lifecycle rules (feed.md 3.6): answers and declines apply only
    /// to open requests, so a request that closed elsewhere shows its closed
    /// state even while this intent is pending; open requests cannot be
    /// archived or snoozed.
    public func apply(to items: inout [String: FeedItem], user: String, device: String) {
        switch kind {
        case let .answer(id, value):
            guard var item = items[id], item.isOpenRequest else { return }
            item.state = .answered
            item.answer = FeedAnswerRecord(value: value, by: user, device: device, at: at)
            item.closedAt = at
            item.readAt = item.readAt ?? at
            items[id] = item
        case let .decline(id):
            guard var item = items[id], item.isOpenRequest else { return }
            item.state = .cancelled
            item.cancel = FeedCancelRecord(reason: .declined, by: user, at: at)
            item.closedAt = at
            item.readAt = item.readAt ?? at
            items[id] = item
        case let .read(ids):
            for id in ids where items[id]?.readAt == nil {
                items[id]?.readAt = at
            }
        case let .archive(ids):
            for id in ids {
                guard var item = items[id], !item.isOpenRequest, item.archivedAt == nil else { continue }
                item.archivedAt = at
                item.readAt = item.readAt ?? at
                items[id] = item
            }
        case let .snooze(ids, until):
            for id in ids {
                guard var item = items[id], !item.isOpenRequest else { continue }
                item.snoozedUntil = until
                items[id] = item
            }
        case let .markAllRead(before):
            for (id, item) in items where item.readAt == nil && item.createdAt <= before {
                items[id]?.readAt = at
            }
        }
    }
}
