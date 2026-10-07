public import Foundation

/// What Search Tabs needs beyond the topology, published with the control
/// snapshot so `tabs.search` answers off the main actor (architecture.md
/// 5a): when each tab was last used, which tabs are closing, and the
/// recently closed tabs.
public struct ControlTabSearchFacts: Sendable, Hashable {
    /// Tab id to when the user last settled on it (the location trail).
    public var lastActive: [String: Date]
    /// Tabs whose close is in flight: gone from their strips already.
    public var closing: Set<String>
    /// Recently closed tabs, oldest first.
    public var closed: [ControlClosedTab]

    public init(lastActive: [String: Date] = [:], closing: Set<String> = [], closed: [ControlClosedTab] = []) {
        self.lastActive = lastActive
        self.closing = closing
        self.closed = closed
    }
}

/// One record of the closed-items log.
public struct ControlClosedTab: Sendable, Hashable {
    /// The closed-items record id (`cmux history reopen <id>`).
    public var id: String
    /// `terminal` or `browser`.
    public var kind: String
    public var title: String
    public var url: String?
    public var cwd: String?
    public var workspaceTitle: String?
    /// The machine name for a tab of another machine; nil on this Mac.
    public var machine: String?
    public var closedAt: Date
    /// False while its machine is not connected.
    public var isAvailable: Bool

    public init(id: String, kind: String, title: String, url: String? = nil, cwd: String? = nil, workspaceTitle: String? = nil,
                machine: String? = nil, closedAt: Date, isAvailable: Bool = true) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.cwd = cwd
        self.workspaceTitle = workspaceTitle
        self.machine = machine
        self.closedAt = closedAt
        self.isAvailable = isAvailable
    }
}
