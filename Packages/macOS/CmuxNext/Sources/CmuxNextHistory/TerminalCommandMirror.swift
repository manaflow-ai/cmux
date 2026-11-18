public import Foundation

/// One machine's stored terminal commands as the App last read them with
/// `list-terminal-commands` (`terminal-command-history-v1`,
/// plans/cmux-next/history.md 6). The daemon owns the rows; this is a read
/// cache. A read after `cursor` appends; when the daemon's version (its
/// registry id and client-delete counter) moved since the last read, or the
/// read left rows out, the mirror resets and the next read starts from the
/// beginning. Expired rows are dropped here: the daemon does not count
/// expiry as a delete.
public nonisolated struct TerminalCommandMirror: Hashable, Sendable {
    public let machine: String
    public let capacity: Int
    /// Oldest first, at most `capacity`.
    public private(set) var commands: [TerminalCommand] = []
    public private(set) var version: String?
    private var lastID: UInt64 = 0
    /// Deletions the App made that its daemon has not confirmed yet: every read applies them, so rows an
    /// offline clear or remove dropped do not come back on a refresh. Kept across a reset.
    public private(set) var pending: [UInt64: Deletion] = [:]
    private var nextPending: UInt64 = 0

    /// Rows the App deletes.
    public enum Deletion: Hashable, Sendable {
        case ids(Set<UInt64>)
        /// Started at or after `since` (nil: from the first) and at or before `until` (the click, so a
        /// command started after it stays).
        case started(since: Date?, until: Date)

        /// A clear of a span (``started(since:until:)``), not a removal by id.
        public var isClear: Bool { if case .started = self { true } else { false } }

        public func covers(_ command: TerminalCommand) -> Bool {
            switch self {
            case .ids(let ids): ids.contains(command.id)
            case .started(let since, let until): since.map { command.startedAt >= $0 } ?? true && command.startedAt <= until
            }
        }
    }

    public init(machine: String, capacity: Int = 1_000) {
        self.machine = machine
        self.capacity = max(1, capacity)
    }

    /// The `after_id` for the next read; nil reads from the beginning.
    public var cursor: UInt64? { version == nil ? nil : lastID }

    /// Applies one page read after `after` (nil: from the beginning) and
    /// drops rows that started at or before `expiredThrough`. Returns false
    /// when appending would leave a gap or keep deleted rows (the version
    /// moved, or the page was truncated): the mirror is reset, and the caller
    /// reads again from the beginning.
    public mutating func apply(_ page: [TerminalCommand], version: String, truncated: Bool, after: UInt64?,
                               expiredThrough: Date? = nil) -> Bool {
        if after != nil, version != self.version || truncated {
            reset()
            return false
        }
        if after == nil {
            commands = page
            lastID = 0
        } else {
            commands += page
        }
        self.version = version
        lastID = max(lastID, page.map(\.id).max() ?? 0)
        if let expiredThrough { commands.removeAll { $0.startedAt <= expiredThrough } }
        commands.removeAll { command in pending.values.contains { $0.covers(command) } }
        if commands.count > capacity { commands.removeFirst(commands.count - capacity) }
        return true
    }

    /// Drops the rows `deletion` covers, now and from every read until ``settle(_:)`` (the daemon confirmed
    /// it); returns the token to settle it with.
    public mutating func delete(_ deletion: Deletion) -> UInt64 {
        nextPending += 1
        pending[nextPending] = deletion
        commands.removeAll { deletion.covers($0) }
        return nextPending
    }

    /// The daemon applied (or refused) the deletion `token` names: reads no longer filter it.
    public mutating func settle(_ token: UInt64) {
        pending[token] = nil
    }

    /// Forgets every row and the read cursor, keeping the pending deletions: the next read starts from the beginning.
    public mutating func reset() {
        let pending = pending, nextPending = nextPending
        self = TerminalCommandMirror(machine: machine, capacity: capacity)
        self.pending = pending
        self.nextPending = nextPending
    }
}
