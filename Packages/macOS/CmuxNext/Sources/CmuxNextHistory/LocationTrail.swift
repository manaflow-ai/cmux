public import Foundation

/// The app-wide "where was I" list with one cursor, for Back and
/// Forward through recent locations (plans/cmux-next/history.md 4.2).
///
/// Pure value type. The App feeds it each settled location (`record`) and
/// asks it where Back and Forward go; `isAvailable` tells it which entries
/// can be focused now (tab alive, machine connected), so it skips the
/// others without dropping them.
public nonisolated struct LocationTrail: Hashable, Sendable, Codable {
    public struct Entry: Hashable, Sendable, Codable {
        public var location: HistoryLocation
        public var enteredAt: Date

        public init(location: HistoryLocation, enteredAt: Date) {
            self.location = location
            self.enteredAt = enteredAt
        }
    }

    enum Move: String, Hashable, Sendable, Codable { case record, back, forward }

    /// Oldest first.
    public private(set) var entries: [Entry] = []
    /// Index of the current entry; -1 when empty.
    public private(set) var cursor: Int = -1
    /// The location a Back or Forward is focusing: its settled focus is
    /// absorbed instead of recorded.
    public private(set) var pending: HistoryLocation.Key?
    /// When the current entry was recorded (nil after a navigation), for
    /// coalescing quick sweeps.
    private var recordedAt: Date?
    private var lastMove: Move = .record

    public let capacity: Int
    /// A location left sooner than this after it was entered is replaced
    /// by the next one (holding Ctrl-Tab records only where you stop).
    public let coalesceInterval: TimeInterval

    public static let defaultCapacity = 200
    public static let defaultCoalesceInterval: TimeInterval = 0.75

    public init(capacity: Int = defaultCapacity, coalesceInterval: TimeInterval = defaultCoalesceInterval) {
        self.capacity = max(1, capacity)
        self.coalesceInterval = coalesceInterval
    }

    public var current: Entry? {
        entries.indices.contains(cursor) ? entries[cursor] : nil
    }

    /// Records a settled location. Returns true when the trail changed.
    @discardableResult
    public mutating func record(_ location: HistoryLocation, at time: Date) -> Bool {
        if let target = pending {
            pending = nil
            if location.key == target {
                refreshCurrent(location)
                return false
            }
        }
        if let current, current.location.key == location.key {
            let changed = current.location != location
            refreshCurrent(location)
            return changed
        }
        let atEnd = cursor == entries.count - 1
        if atEnd, let recordedAt, time.timeIntervalSince(recordedAt) < coalesceInterval, cursor >= 0 {
            // A quick sweep: the current entry was only passed through.
            entries.remove(at: cursor)
            cursor -= 1
            if let previous = self.current, previous.location.key == location.key {
                refreshCurrent(location)
                self.recordedAt = nil
                lastMove = .record
                return true
            }
        }
        if cursor < entries.count - 1 { entries.removeSubrange((cursor + 1)...) }
        entries.append(Entry(location: location, enteredAt: time))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        cursor = entries.count - 1
        recordedAt = time
        lastMove = .record
        return true
    }

    /// Moves to the newest older entry that `isAvailable`, marks it pending,
    /// and returns it (nil: nothing to go back to).
    public mutating func back(isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Entry? {
        guard let index = olderIndex(isAvailable) else { return nil }
        return move(to: index, .back)
    }

    /// Moves to the oldest newer entry that `isAvailable`.
    public mutating func forward(isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Entry? {
        guard let index = newerIndex(isAvailable) else { return nil }
        return move(to: index, .forward)
    }

    /// Go to Last Location: toggles between the current entry and the one
    /// the user came from (Back, or Forward right after a Back).
    public mutating func last(isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Entry? {
        if lastMove == .back, let entry = forward(isAvailable: isAvailable) { return entry }
        return back(isAvailable: isAvailable)
    }

    public func canGoBack(isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Bool {
        olderIndex(isAvailable) != nil
    }

    public func canGoForward(isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Bool {
        newerIndex(isAvailable) != nil
    }

    /// Moves to the entry at `index` (a row of a Back or Forward list) and marks it pending, like
    /// Back and Forward do; nil for an index outside the trail.
    public mutating func go(to index: Int) -> Entry? {
        guard entries.indices.contains(index) else { return nil }
        return move(to: index, index < cursor ? .back : .forward)
    }

    /// Clears a pending navigation that could not land (the tab vanished).
    public mutating func cancelPending() {
        pending = nil
    }

    /// Refreshes the stored context (title, pane, window) of every entry of
    /// `key`, since titles change without a new location.
    public mutating func refresh(_ location: HistoryLocation) {
        for index in entries.indices where entries[index].location.key == location.key {
            entries[index].location = location
        }
    }

    /// Drops matching entries, keeping the cursor on the same entry when it
    /// survives, else on the newest older survivor.
    public mutating func removeAll(where shouldRemove: (Entry) -> Bool) {
        var kept: [Entry] = []
        var newCursor = -1
        for (index, entry) in entries.enumerated() {
            if !shouldRemove(entry) { kept.append(entry) }
            if index == cursor { newCursor = kept.count - 1 }
        }
        if newCursor < 0, !kept.isEmpty { newCursor = 0 }
        entries = kept
        cursor = kept.isEmpty ? -1 : newCursor
        if let target = pending, !kept.contains(where: { $0.location.key == target }) { pending = nil }
        if current == nil { recordedAt = nil }
    }

    /// The trail without incognito entries: what may be written to disk.
    public var persistable: LocationTrail {
        var copy = self
        copy.pending = nil
        copy.removeAll { $0.location.isIncognito }
        return copy
    }

    private mutating func refreshCurrent(_ location: HistoryLocation) {
        guard entries.indices.contains(cursor) else { return }
        entries[cursor].location = location
    }

    private mutating func move(to index: Int, _ direction: Move) -> Entry {
        cursor = index
        pending = entries[index].location.key
        recordedAt = nil
        lastMove = direction
        return entries[index]
    }

    private func olderIndex(_ isAvailable: (HistoryLocation) -> Bool) -> Int? {
        guard cursor > 0 else { return nil }
        return (0..<cursor).reversed().first { isAvailable(entries[$0].location) && entries[$0].location.key != current?.location.key }
    }

    private func newerIndex(_ isAvailable: (HistoryLocation) -> Bool) -> Int? {
        guard cursor + 1 < entries.count else { return nil }
        return ((cursor + 1)..<entries.count).first { isAvailable(entries[$0].location) && entries[$0].location.key != current?.location.key }
    }
}
