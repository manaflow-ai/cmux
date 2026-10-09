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
            self = TerminalCommandMirror(machine: machine, capacity: capacity)
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
        if commands.count > capacity { commands.removeFirst(commands.count - capacity) }
        return true
    }

    /// Drops rows the App asked the daemon to delete, before the next read.
    public mutating func remove(ids: Set<UInt64>) {
        commands.removeAll { ids.contains($0.id) }
    }

    /// Drops rows that started at or after `since` (nil: all).
    public mutating func remove(startedSince since: Date?) {
        guard let since else { return commands.removeAll() }
        commands.removeAll { $0.startedAt >= since }
    }
}
