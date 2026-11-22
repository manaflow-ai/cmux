public import Foundation

/// Recently closed tabs, for "Reopen Closed Tab". The App feeds it
/// every tab it sees; a tab that disappears while its workspace still
/// exists counts as closed (moves keep their durable id, so they do not).
public nonisolated struct ClosedTabHistory: Sendable {
    public struct Record: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case terminal, browser }
        public var kind: Kind
        public var tabID: String
        public var paneID: String
        public var workspaceID: String
        public var index: Int
        public var cwd: String?
        public var url: String?
        /// A browser tab's engine tag (`webkit`, `cef`); reopening keeps it.
        public var engine: String?
        /// The closed tab's terminal (`term_…`). Closing a tab only detaches
        /// it; the daemon ends it after its reap grace period, so reopening
        /// within that window shows the same live terminal.
        public var terminalResourceID: String?
        /// The tab's last title, for history lists.
        public var title: String?
        /// When the App saw the tab disappear.
        public var closedAt: Date?

        public init(kind: Kind, tabID: String, paneID: String, workspaceID: String, index: Int,
                    cwd: String? = nil, url: String? = nil, engine: String? = nil, terminalResourceID: String? = nil,
                    title: String? = nil, closedAt: Date? = nil) {
            self.kind = kind
            self.tabID = tabID
            self.paneID = paneID
            self.workspaceID = workspaceID
            self.index = index
            self.cwd = cwd
            self.url = url
            self.engine = engine
            self.terminalResourceID = terminalResourceID
            self.title = title
            self.closedAt = closedAt
        }
    }

    public let capacity: Int
    /// Oldest first; `popLast()` reopens the newest.
    public private(set) var closed: [Record] = []
    private var known: [String: Record] = [:]

    public init(capacity: Int = 25) {
        self.capacity = capacity
    }

    /// Diffs `current` (every open tab) against the last call. `latest`
    /// refreshes a closed tab's details (cwd, url, terminal) from the App's last view
    /// of it, since those change without a structural update.
    public mutating func observe(_ current: [Record], liveWorkspaces: Set<String>,
                                 latest: (Record) -> Record = { $0 }) {
        let next = Dictionary(current.map { ($0.tabID, $0) }, uniquingKeysWith: { first, _ in first })
        let gone = known.values.filter { next[$0.tabID] == nil && liveWorkspaces.contains($0.workspaceID) }
        closed.append(contentsOf: gone.sorted { ($0.paneID, $0.index) < ($1.paneID, $1.index) }.map(latest))
        if closed.count > capacity { closed.removeFirst(closed.count - capacity) }
        known = next
    }

    /// Forgets the baseline without recording closes (daemon restart).
    public mutating func resetBaseline() {
        known = [:]
    }

    public mutating func popLast() -> Record? {
        closed.popLast()
    }

    /// Takes one record out (reopen from a history list).
    public mutating func remove(tabID: String) -> Record? {
        guard let index = closed.lastIndex(where: { $0.tabID == tabID }) else { return nil }
        return closed.remove(at: index)
    }

    /// Forgets records closed at or after `since` (nil: all).
    public mutating func removeAll(since: Date?) {
        closed.removeAll { record in since.map { (record.closedAt ?? .distantPast) >= $0 } ?? true }
    }
}
