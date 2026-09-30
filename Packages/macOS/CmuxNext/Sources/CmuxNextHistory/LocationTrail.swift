public import Foundation

/// The app-wide "where was I" list with one cursor: Vim's jumplist, VS
/// Code's Go Back, Xcode's history arrows (plans/cmux-next/history.md 4.2).
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
        false
    }

    /// Moves to the newest older entry that `isAvailable`, marks it pending,
    /// and returns it (nil: nothing to go back to).
    public mutating func back(isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Entry? {
        nil
    }

    /// Moves to the oldest newer entry that `isAvailable`.
    public mutating func forward(isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Entry? {
        nil
    }

    /// Go to Last Location: toggles between the current entry and the one
    /// the user came from (Back, or Forward right after a Back).
    public mutating func last(isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Entry? {
        nil
    }

    public func canGoBack(isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Bool {
        false
    }

    public func canGoForward(isAvailable: (HistoryLocation) -> Bool = { _ in true }) -> Bool {
        false
    }

    /// Clears a pending navigation that could not land (the tab vanished).
    public mutating func cancelPending() {
        pending = nil
    }

    /// Refreshes the stored context (title, pane, window) of every entry of
    /// `key`, since titles change without a new location.
    public mutating func refresh(_ location: HistoryLocation) {}

    /// Drops matching entries, keeping the cursor on the same entry when it
    /// survives, else on the newest older survivor.
    public mutating func removeAll(where shouldRemove: (Entry) -> Bool) {}

    /// The trail without incognito entries: what may be written to disk.
    public var persistable: LocationTrail {
        self
    }
}
