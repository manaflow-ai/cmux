public import Foundation

/// The owner of an item: the user's `FeedDO` or one daemon's local owner
/// (feed.md section 5). Changes only by the handoff op.
public nonisolated enum FeedHome: Sendable, Equatable, Hashable {
    case cloud
    case local(install: String)

    /// Local items carry a "this Mac only" badge.
    public var isLocal: Bool {
        if case .local = self { return true }
        return false
    }
}

public nonisolated enum FeedPriority: String, Sendable, Equatable, CaseIterable, Comparable {
    case low
    case normal
    case high
    case urgent

    /// Higher sorts first.
    public var rank: Int {
        switch self {
        case .low: 0
        case .normal: 1
        case .high: 2
        case .urgent: 3
        }
    }

    public static func < (lhs: FeedPriority, rhs: FeedPriority) -> Bool { lhs.rank < rhs.rank }
}

/// What an item is about. All optional; opening an item opens its context.
public nonisolated struct FeedContext: Sendable, Equatable, Hashable {
    public var host: String?
    public var workspace: String?
    public var tab: String?
    public var terminal: String?
    public var browserTab: String?
    public var acpSession: String?
    public var task: String?
    public var url: URL?

    public init(
        host: String? = nil, workspace: String? = nil, tab: String? = nil, terminal: String? = nil,
        browserTab: String? = nil, acpSession: String? = nil, task: String? = nil, url: URL? = nil
    ) {
        self.host = host
        self.workspace = workspace
        self.tab = tab
        self.terminal = terminal
        self.browserTab = browserTab
        self.acpSession = acpSession
        self.task = task
        self.url = url
    }

    public var isEmpty: Bool { self == FeedContext() }
}
