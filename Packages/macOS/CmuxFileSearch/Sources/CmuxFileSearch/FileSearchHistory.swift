/// Past search patterns, oldest first, without duplicates.
public struct FileSearchHistory: Hashable, Sendable, Codable {
    public static let defaultCapacity = 50

    public private(set) var entries: [String]
    public let capacity: Int

    public init(entries: [String] = [], capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
        self.entries = []
        for entry in entries { record(entry) }
    }

    /// Adds `pattern` as the newest entry, moving an existing copy.
    public mutating func record(_ pattern: String) {
        guard !pattern.isEmpty else { return }
        entries.removeAll { $0 == pattern }
        entries.append(pattern)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}

/// Up/Down navigation through a ``FileSearchHistory`` from a query field.
///
/// The first step back remembers what the user had typed, and stepping
/// forward past the newest entry returns to it, as in VS Code.
public struct FileSearchHistoryCursor: Hashable, Sendable {
    private var index: Int?
    private var draft = ""

    public init() {}

    /// True while the field shows a history entry rather than typed text.
    public var isBrowsing: Bool { index != nil }

    /// The entry before the current one, or `nil` at the oldest entry.
    public mutating func previous(in history: FileSearchHistory, current: String) -> String? {
        guard !history.entries.isEmpty else { return nil }
        if let index {
            guard index > 0 else { return nil }
            self.index = index - 1
        } else {
            draft = current
            var start = history.entries.count - 1
            // Skip the newest entry when it is what the field already shows.
            if history.entries[start] == current {
                guard start > 0 else { return nil }
                start -= 1
            }
            index = start
        }
        return history.entries[index!]
    }

    /// The entry after the current one, the saved draft past the newest, or
    /// `nil` when not browsing.
    public mutating func next(in history: FileSearchHistory) -> String? {
        guard let index else { return nil }
        if index + 1 < history.entries.count {
            self.index = index + 1
            return history.entries[index + 1]
        }
        self.index = nil
        return draft
    }

    /// Typing ends browsing.
    public mutating func reset() {
        index = nil
        draft = ""
    }
}
