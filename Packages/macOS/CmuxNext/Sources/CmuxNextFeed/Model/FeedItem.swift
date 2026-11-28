public import Foundation

/// One feed item (plans/cmux-next/feed.md 3.1): a notice or a request, with
/// a lifecycle state (owner) and a triage state (owner, set by the user's
/// ops). The client never writes one: it mirrors the owner's items and
/// overlays its pending intents (`FeedIntent.apply`).
public nonisolated struct FeedItem: Sendable, Equatable, Identifiable {
    /// `fi_` + 20, stable across a home transfer.
    public var id: String
    public var home: FeedHome
    public var title: String
    /// Markdown, at most 4096 characters.
    public var body: String
    /// The kind-specific prompt. Carries the kind, so `kind` and `type`
    /// never disagree with it.
    public var prompt: FeedPrompt
    public var priority: FeedPriority
    public var dedupeKey: String?
    /// Groups items of one poster scope for display (one agent session).
    public var thread: String?
    public var context: FeedContext
    public var attachments: [FeedAttachment]
    public var actions: [FeedAction]
    public var expiresAt: Date?
    public var poster: FeedPoster
    public var state: FeedItemState
    public var answer: FeedAnswerRecord?
    public var cancel: FeedCancelRecord?
    public var readAt: Date?
    public var seenAt: Date?
    public var archivedAt: Date?
    public var snoozedUntil: Date?
    /// How many posts the dedupe key coalesced.
    public var count: Int
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var closedAt: Date?

    public init(
        id: String, home: FeedHome = .cloud, title: String, body: String = "", prompt: FeedPrompt = .notice,
        priority: FeedPriority? = nil, dedupeKey: String? = nil, thread: String? = nil,
        context: FeedContext = FeedContext(), attachments: [FeedAttachment] = [], actions: [FeedAction] = [],
        expiresAt: Date? = nil, poster: FeedPoster, state: FeedItemState = .open,
        answer: FeedAnswerRecord? = nil, cancel: FeedCancelRecord? = nil, readAt: Date? = nil, seenAt: Date? = nil,
        archivedAt: Date? = nil, snoozedUntil: Date? = nil, count: Int = 1, revision: Int = 1,
        createdAt: Date, updatedAt: Date? = nil, closedAt: Date? = nil
    ) {
        self.id = id
        self.home = home
        self.title = title
        self.body = body
        self.prompt = prompt
        self.priority = priority ?? prompt.defaultPriority
        self.dedupeKey = dedupeKey
        self.thread = thread
        self.context = context
        self.attachments = attachments
        self.actions = actions
        self.expiresAt = expiresAt
        self.poster = poster
        self.state = state
        self.answer = answer
        self.cancel = cancel
        self.readAt = readAt
        self.seenAt = seenAt
        self.archivedAt = archivedAt
        self.snoozedUntil = snoozedUntil
        self.count = count
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.closedAt = closedAt
    }

    /// `notice` for notices, else the registry kind (`approve`, `x-acme.deploy`).
    public var kind: String { prompt.kind }
    public var type: FeedItemType { prompt.isNotice ? .notice : .request }
    public var isRequest: Bool { type == .request }
    /// A request still waiting for its answer.
    public var isOpenRequest: Bool { isRequest && state == .open }
    public var isUnread: Bool { readAt == nil }
    public var isArchived: Bool { archivedAt != nil }

    /// Snoozed until a moment after `now`: out of the active lists.
    public func isSnoozed(at now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now
    }

    /// In the active lists: not archived, not snoozed.
    public func isActive(at now: Date) -> Bool { !isArchived && !isSnoozed(at: now) }

    /// The diff attachment an `approve` or `review` prompt names, else the
    /// first diff-like attachment.
    public var diffAttachment: FeedAttachment? {
        if case let .approve(approve) = prompt, let id = approve.action.diff,
           let named = attachments.first(where: { $0.id == id }) {
            return named
        }
        return attachments.first { $0.isDiff }
    }
}

public nonisolated enum FeedItemType: String, Sendable, Equatable {
    case notice
    case request
}

/// Lifecycle (feed.md 3.6). Answered, cancelled and expired are final.
public nonisolated enum FeedItemState: String, Sendable, Equatable {
    case open
    case answered
    case cancelled
    case expired

    public var isClosed: Bool { self != .open }
}
