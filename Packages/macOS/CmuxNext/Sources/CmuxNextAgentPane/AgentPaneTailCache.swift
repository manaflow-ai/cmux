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
/// rest of the session's state (``clear()``). What is held is bounded three ways here, so the
/// bound holds whatever a page sends: the most recent ``chats`` chats, ``events`` records of each,
/// and ``bytes`` of each (``holds(_:)``) — at most about 20 MiB in the worst case, and a small
/// fraction of that for ordinary chats, which are far under the per-chat bound.
///
/// The page bounds a tail to 256 KiB of its own before handing it over (acpmux/tailCache.ts
/// `HOST_TAIL_BYTES`), which is the number that describes real use. ``bytes`` is deliberately
/// larger rather than equal: it is a backstop against a page that bounds wrongly or not at all,
/// and the two sides count differently — the page measures `JSON.stringify().length` in UTF-16
/// units, this measures UTF-8 bytes, and one CJK character is 1 unit there and 3 bytes here. An
/// equal number would silently refuse a correct page's tail for a chat that is not in English, so
/// the chat would quietly open cold in the next tab.
///
/// The tail itself is the page's own shape, kept opaque: only the page reads it back.
@MainActor
public final class AgentPaneTailCache {
    public static let shared = AgentPaneTailCache()
    /// Chats whose tail is kept, as the page keeps the same number.
    static let chats = 20
    /// Most records one chat's tail may carry, as many as an attach page holds. A tail over this
    /// is refused whole, never cut: a cut tail that still called its history exhausted would hide
    /// the chat's older turns (webviews/test/reopened-chat-history.test.ts).
    static let events = 400
    /// Most bytes one chat's tail may carry, as its compact JSON in UTF-8. Four times the page's
    /// own 256 KiB, for the reason in this type's documentation: enough that a correct page is
    /// never refused in any language, small enough that a page that bounds nothing cannot grow
    /// this without limit. A tail over it is refused whole, as an over-long one is.
    static let bytes = 1024 * 1024

    private struct Entry {
        var sessionId: String
        var tail: JSONValue
    }

    /// Least recently remembered first.
    private var entries: [Entry] = []

    /// ``shared`` is the one store both hosts answer from. A second one would split the cache: a
    /// tail handed to one would be invisible to the other, and a chat would open cold for no
    /// reason a reader could see.
    private init() {}

    /// The tail kept for `sessionId`, or nil when none is.
    public func tail(for sessionId: String) -> JSONValue? {
        entries.last { $0.sessionId == sessionId }?.tail
    }

    /// Keeps `tail` for chat `sessionId`; nil forgets it (the page no longer stands behind that
    /// transcript). A tail this does not hold (``holds(_:)``) is refused, which leaves the chat to
    /// open from acpmux as it did before — and it also drops any tail already kept for that chat,
    /// because the page has read on since and this one is what it now stands behind.
    public func remember(_ tail: JSONValue?, for sessionId: String) {
        var kept = entries.filter { $0.sessionId != sessionId }
        if let tail, Self.holds(tail) { kept.append(Entry(sessionId: sessionId, tail: tail)) }
        entries = Array(kept.suffix(Self.chats))
    }

    /// Keeps `tail` for chat `sessionId` only when it ends on a newer record than the tail kept now
    /// (or none is kept): a sidebar hover's hand-over (`ifNewer`, acpmux/tailCache.ts
    /// `shareReadAhead`). Compared and replaced in one step here, the one store, so another tab's
    /// newer hand-over between a page's read and its write is never undone; a tie keeps the kept
    /// tail, which is the fuller one (a page's own read, where a read ahead is a smaller page).
    public func rememberIfNewer(_ tail: JSONValue, for sessionId: String) {
        if let kept = self.tail(for: sessionId), Self.newestSeq(kept) >= Self.newestSeq(tail) { return }
        guard Self.holds(tail) else { return }
        remember(tail, for: sessionId)
    }

    /// The newest record's `seq` in `tail`; 0 when it has none.
    static func newestSeq(_ tail: JSONValue) -> Double {
        (tail["events"]?.arrayValue ?? []).compactMap { $0["seq"]?.doubleValue }.max() ?? 0
    }

    /// Forgets every tail: the session's chats are no longer this person's.
    public func clear() {
        entries.removeAll()
    }

    /// Whether `tail` is a page tail this keeps: records, not too many of them, and not too large.
    /// The byte bound is measured over the whole tail and not only its records, because the rest of
    /// it is not bounded by a record count — a chat's `queue` carries the full text of every
    /// prompt waiting to be sent, so a queued paste is what would grow this.
    private static func holds(_ tail: JSONValue) -> Bool {
        guard case .object(let fields) = tail, case .array(let events)? = fields["events"] else { return false }
        guard !events.isEmpty, events.count <= Self.events else { return false }
        var text = ""
        tail.appendCompactText(to: &text)
        return text.utf8.count <= Self.bytes
    }
}
