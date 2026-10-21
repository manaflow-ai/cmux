public import CmuxNextSettings
public import Foundation

/// What each agent chat's page last read of it, so the same chat opened in another tab draws at
/// once instead of after acpmux's attach round trip (Leo 2026-10-20: a chat "should be instant if
/// cached"). A pane's page keeps its own chats' tails, which is all a switch inside one pane needs;
/// a new tab is a new page, with none, so every page hands its tails here (`chat.tail`) and asks
/// for one before it attaches (`chat.tail.get`, acpmux/tailCache.ts).
///
/// IN MEMORY ONLY. Nothing is written to disk, so this adds no place a transcript persists and no
/// setting to turn off: quitting the app forgets every tail, and signing out drops them with the
/// rest of the session's state (``clear()``). What is held is bounded three ways: the most recent
/// ``chats`` chats, ``events`` records of each, and the bytes the page bounds before it hands a
/// tail over (acpmux/tailCache.ts `HOST_TAIL_BYTES`), which together come to about 2 MiB.
///
/// The tail itself is the page's own shape, kept opaque: only the page reads it back, and a record
/// count is all this needs to bound what it holds.
@MainActor
public final class AgentPaneTailCache {
    public static let shared = AgentPaneTailCache()
    /// Chats whose tail is kept, as the page keeps the same number.
    static let chats = 8
    /// Most records one chat's tail may carry, as many as an attach page holds. A tail over this
    /// is refused whole, never cut: a cut tail that still called its history exhausted would hide
    /// the chat's older turns (webviews/test/reopened-chat-history.test.ts).
    static let events = 400

    private struct Entry {
        var sessionId: String
        var tail: JSONValue
    }

    /// Least recently remembered first.
    private var entries: [Entry] = []

    public init() {}

    /// The tail kept for `sessionId`, or nil when none is.
    public func tail(for sessionId: String) -> JSONValue? {
        entries.last { $0.sessionId == sessionId }?.tail
    }

    /// Keeps `tail` for chat `sessionId`; nil forgets it (the page no longer stands behind that
    /// transcript). A tail carrying more than ``events`` records is refused, which leaves the chat
    /// to open from acpmux as it did before.
    public func remember(_ tail: JSONValue?, for sessionId: String) {
        var kept = entries.filter { $0.sessionId != sessionId }
        if let tail, Self.holds(tail) { kept.append(Entry(sessionId: sessionId, tail: tail)) }
        entries = Array(kept.suffix(Self.chats))
    }

    /// Forgets every tail: the session's chats are no longer this person's.
    public func clear() {
        entries.removeAll()
    }

    /// Whether `tail` is a page tail this keeps: records, and not too many of them.
    private static func holds(_ tail: JSONValue) -> Bool {
        guard case .object(let fields) = tail, case .array(let events)? = fields["events"] else { return false }
        return !events.isEmpty && events.count <= Self.events
    }
}
