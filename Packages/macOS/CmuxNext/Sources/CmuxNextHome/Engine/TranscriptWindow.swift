public import Foundation

/// What a window mutation did to the message list, so rows update only there.
nonisolated enum WindowChange: Equatable, Sendable {
    case none
    /// Replaced: derive every row again.
    case full
    /// `count` messages joined at the front.
    case prepend(Int)
    /// `count` messages left the front / the back.
    case evictTop(Int)
    case evictBottom(Int)
    /// Messages at these indexes (after the change) were added or changed.
    case touched(IndexSet)
}

/// The bounded slice of a conversation the renderer holds: a contiguous run of
/// confirmed messages (`firstSeq...`) plus, when it reaches the newest
/// message, the pending sends after them. At most ``maxMessages`` confirmed
/// messages (architecture.md 4: the app never holds the whole log).
nonisolated struct TranscriptWindow: Sendable {
    static var maxMessages: Int { 3200 }

    private(set) var confirmed = ChunkedList<HomeMessage>()
    private(set) var pending: [HomeMessage] = []
    /// Seq of `confirmed[0]` (the next seq to load when empty).
    private(set) var firstSeq: Int = 1
    /// Oldest seq the source still has.
    var oldestAvailable: Int = 1
    /// Newest confirmed seq the source has.
    var newestKnown: Int = 0

    var lastSeq: Int { firstSeq + confirmed.count - 1 }
    var atNewest: Bool { lastSeq >= newestKnown }
    var hasOlder: Bool { firstSeq > oldestAvailable }
    /// Messages the transcript shows: confirmed, then pending when at the newest end.
    var count: Int { confirmed.count + (atNewest ? pending.count : 0) }

    subscript(index: Int) -> HomeMessage {
        index < confirmed.count ? confirmed[index] : pending[index - confirmed.count]
    }

    func index(ofRowKey key: String) -> Int? {
        if let p = pending.firstIndex(where: { $0.rowKey == key }) { return atNewest ? confirmed.count + p : nil }
        guard let i = confirmed.lastIndex(where: { $0.rowKey == key }) else { return nil }
        return i
    }

    /// Replaces the window with `messages` (ascending, contiguous).
    mutating func replace(_ messages: [HomeMessage], pending: [HomeMessage], newest: Int, oldest: Int) -> WindowChange {
        confirmed = ChunkedList(messages)
        firstSeq = messages.first?.seq ?? (newest + 1)
        self.pending = pending
        newestKnown = newest
        oldestAvailable = oldest
        return .full
    }

    /// Older messages that end right before `firstSeq`.
    mutating func prepend(_ messages: [HomeMessage]) -> WindowChange {
        guard let last = messages.last?.seq, last == firstSeq - 1 || confirmed.isEmpty else { return .none }
        confirmed.prepend(contentsOf: messages)
        firstSeq = messages.first?.seq ?? firstSeq
        return .prepend(messages.count)
    }

    /// Newer confirmed messages that start right after `lastSeq`.
    mutating func appendConfirmed(_ messages: [HomeMessage]) -> WindowChange {
        let fresh = messages.filter { ($0.seq ?? 0) > lastSeq }
        guard let first = fresh.first?.seq, first == lastSeq + 1 else {
            if let newest = messages.last?.seq { newestKnown = max(newestKnown, newest) }
            return .none
        }
        let start = confirmed.count
        confirmed.append(contentsOf: fresh)
        newestKnown = max(newestKnown, lastSeq)
        // pending rows sit after the new confirmed ones (or just became visible): they moved too
        return .touched(IndexSet(integersIn: start..<count))
    }

    /// The source announced newer messages the window does not hold.
    mutating func noteNewest(_ seq: Int) { newestKnown = max(newestKnown, seq) }

    mutating func update(_ message: HomeMessage) -> WindowChange {
        guard let seq = message.seq, seq >= firstSeq, seq <= lastSeq else { return .none }
        let i = seq - firstSeq
        guard confirmed[i] != message else { return .none }
        confirmed[i] = message
        return .touched([i])
    }

    mutating func addPending(_ message: HomeMessage) -> WindowChange {
        if let i = pending.firstIndex(where: { $0.clientMsgID == message.clientMsgID }) {
            pending[i] = message
            return atNewest ? .touched([confirmed.count + i]) : .none
        }
        pending.append(message)
        return atNewest ? .touched([count - 1]) : .none
    }

    /// The pending send becomes `confirmed` with its seq; same row key, so it settles in place.
    mutating func resolvePending(clientMsgID: String, confirmed message: HomeMessage) -> WindowChange {
        let wasAtNewest = atNewest
        let from = pending.firstIndex { $0.clientMsgID == clientMsgID }.map { confirmed.count + $0 }
        pending.removeAll { $0.clientMsgID == clientMsgID }
        guard let seq = message.seq else { return .none }
        if seq <= lastSeq { return update(message) }
        if seq == lastSeq + 1 {
            confirmed.append(message)
            newestKnown = max(newestKnown, seq)
        } else {
            noteNewest(seq)
        }
        guard wasAtNewest || atNewest else { return .none }
        let start = min(from ?? confirmed.count - 1, max(0, confirmed.count - 1))
        return .touched(IndexSet(integersIn: max(0, start)..<max(count, start + 1)))
    }

    mutating func failPending(clientMsgID: String, reason: String) -> WindowChange {
        guard let i = pending.firstIndex(where: { $0.clientMsgID == clientMsgID }) else { return .none }
        pending[i].delivery = .failed(reason)
        return atNewest ? .touched([confirmed.count + i]) : .none
    }

    /// Drops messages from the front or the back to stay within the bound.
    mutating func evict(top: Int, bottom: Int) -> WindowChange {
        let top = min(top, confirmed.count)
        let bottom = min(bottom, confirmed.count - top)
        guard top > 0 || bottom > 0 else { return .none }
        let before = count
        confirmed.remove(top: top, bottom: bottom)
        firstSeq += top
        if top > 0, bottom > 0 { return .full }
        // leaving the newest end also hides the pending rows
        return top > 0 ? .evictTop(top) : .evictBottom(before - count)
    }
}
