public import CmuxNextSettings
public import Foundation

/// What each agent chat's page last read of it, so the same chat opened in another tab draws at
/// once instead of after acpmux's attach round trip (Leo 2026-10-20: a chat "should be instant if
/// cached"). A pane's page keeps its own chats' tails, which is all a switch inside one pane needs;
/// a new tab is a new page, with none, so every page hands its tails here (`chat.tail`) and asks
/// for one before it attaches (`chat.tail.get`, acpmux/tailCache.ts).
///
/// Under this memory tier is a disk tier (``disk``, ``AgentPaneTailDisk``): each tail kept here is
/// also saved there off the main thread, and a memory miss reads it there, also off the main
/// thread, so a chat opened from the sidebar or a link in a new tab, or after a restart, draws its
/// rows before its attach (Leo, 2026-11-05: "There's no reason for them to have a delay, even under
/// load."). A miss there is forwarded to acpmux's bounded disk snapshot store for peer chats
/// (``AgentPaneHostProviding/peerSnapshot(sessionId:)``). Leo's 2026-11-03 instant-open
/// requirement replaces the earlier memory-only transcript policy. Sign-out clears both tiers
/// with ``clear()``. What is held is bounded three ways here, so the
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
    /// The disk tier; nil keeps tails in memory only (a test host, the gallery). Unless set, it is
    /// the `agent-chat-tails` folder beside the app's other agent-pane state files (the launch
    /// snapshot's folder, where ``AgentPaneScrollAnchors`` keeps where each chat rests), made on
    /// first use, once the app has made that store, and owned by the app's state files
    /// (``AgentPaneStateFiles/tails(in:)``), so the quit awaits its saves.
    public var disk: AgentPaneTailDisk? {
        get {
            if let configuredDisk { return configuredDisk }
            guard let anchors = AgentPaneScrollAnchors.shared else { return nil }
            let disk = anchors.file.map { anchors.files.tails(in: $0.deletingLastPathComponent().appending(path: "agent-chat-tails")) }
            configuredDisk = .some(disk)
            return disk
        }
        set { configuredDisk = .some(newValue) }
    }
    private var configuredDisk: AgentPaneTailDisk??
    /// Chats whose tail is kept, as the page keeps the same number.
    public nonisolated static let chats = 20
    /// Most records one chat's tail may carry, as many as an attach page holds. A tail over this
    /// is refused whole, never cut: a cut tail that still called its history exhausted would hide
    /// the chat's older turns (webviews/test/reopened-chat-history.test.ts).
    nonisolated static let events = 400
    /// Most bytes one chat's tail may carry, as its compact JSON in UTF-8. Four times the page's
    /// own 256 KiB, for the reason in this type's documentation: enough that a correct page is
    /// never refused in any language, small enough that a page that bounds nothing cannot grow
    /// this without limit. A tail over it is refused whole, as an over-long one is.
    public nonisolated static let bytes = 1024 * 1024

    private struct Entry {
        var sessionId: String
        var tail: JSONValue
    }

    /// Least recently remembered first.
    private var entries: [Entry] = []
    private(set) var generation: UInt64 = 0
    private(set) var acceptsTails = true
    /// The chats a disk read is under way for: how many reads, and how often the chat's kept tail
    /// changed since the first began. A read that sees a change since it began does not put what it
    /// read back (#36492 review F2: a forget during the read was undone). Only while reads are under
    /// way, so it holds at most one entry per read in flight.
    private var reads: [String: (count: Int, changes: UInt64)] = [:]
    /// The `ifNewer` hand-overs comparing against the disk tier (``rememberIfNewer(_:for:)``), each
    /// until its one disk read answers.
    private var comparisons: [UInt64: Task<Void, Never>] = [:]
    private var comparisonCount: UInt64 = 0

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
        guard acceptsTails else { return }
        // Typed: `JSONValue` is `ExpressibleByNilLiteral`, so an untyped `nil` here was `.null`, and a
        // refused tail was kept as `.null` instead of forgotten.
        let held: JSONValue? = if let tail, Self.holds(tail) { tail } else { nil }
        hold(held, for: sessionId)
        disk?.write(held, for: sessionId)
    }

    /// Keeps `tail` in memory only: what the disk tier read back, which it already holds.
    private func hold(_ tail: JSONValue?, for sessionId: String) {
        reads[sessionId]?.changes &+= 1
        var kept = entries.filter { $0.sessionId != sessionId }
        if let tail { kept.append(Entry(sessionId: sessionId, tail: tail)) }
        entries = Array(kept.suffix(Self.chats))
    }

    /// The tail the disk tier holds for `sessionId`, read off the main thread, and then held in
    /// memory too; nil when it holds none. When the chat's tail changed while it read, what memory
    /// holds now instead (a newer tail handed over), or nil (the page forgot it, or handed over one
    /// this refused): the read is from before that, so it never puts the old copy back. Nil too
    /// when the lifecycle changed (sign-out cleared both tiers).
    func diskTail(for sessionId: String) async -> JSONValue? {
        guard let disk, acceptsTails else { return nil }
        let generation = generation
        let began = beginRead(of: sessionId)
        let read = await disk.read(sessionId)
        let unchanged = endRead(of: sessionId, began: began)
        guard generation == self.generation, acceptsTails else { return nil }
        if let kept = tail(for: sessionId) { return kept }
        guard unchanged, let read else { return nil }
        hold(read, for: sessionId)
        return read
    }

    /// Marks a disk read of `sessionId` under way; its answer is the change count to compare.
    private func beginRead(of sessionId: String) -> UInt64 {
        var entry = reads[sessionId] ?? (count: 0, changes: 0)
        entry.count += 1
        reads[sessionId] = entry
        return entry.changes
    }

    /// Ends a disk read of `sessionId`; whether the chat's tail stayed as it was when it began. A
    /// ``clear()`` while it read dropped the entry, which also reads as changed.
    private func endRead(of sessionId: String, began: UInt64) -> Bool {
        guard var entry = reads[sessionId] else { return false }
        let unchanged = entry.changes == began
        entry.count -= 1
        reads[sessionId] = entry.count == 0 ? nil : entry
        return unchanged
    }

    /// Keeps `tail` for chat `sessionId` only when it ends on a newer record than the tail kept now
    /// (or none is kept): a sidebar hover's hand-over (`ifNewer`, acpmux/tailCache.ts
    /// `shareReadAhead`). Compared and replaced in one step here, the one store, so another tab's
    /// newer hand-over between a page's read and its write is never undone; a tie keeps the kept
    /// tail, which is the fuller one (a page's own read, where a read ahead is a smaller page).
    ///
    /// The tail kept now includes the disk tier's: with none in memory (after a relaunch) this
    /// compares against the disk's copy, read off the main thread, before it keeps anything, so an
    /// older read ahead never replaces a newer tail an earlier launch saved (#36492 review F1). A
    /// change to the chat's tail while that read runs wins over both.
    public func rememberIfNewer(_ tail: JSONValue, for sessionId: String) {
        guard acceptsTails, Self.holds(tail) else { return }
        if let kept = self.tail(for: sessionId) {
            if Self.newestSeq(kept) < Self.newestSeq(tail) { remember(tail, for: sessionId) }
            return
        }
        guard let disk else {
            remember(tail, for: sessionId)
            return
        }
        let generation = generation
        let began = beginRead(of: sessionId)
        comparisonCount &+= 1
        let number = comparisonCount
        comparisons[number] = Task {
            let stored = await disk.read(sessionId)
            defer { comparisons[number] = nil }
            let unchanged = endRead(of: sessionId, began: began)
            guard generation == self.generation, acceptsTails else { return }
            guard unchanged else {
                // Handed over or forgotten meanwhile: compare against that, as if it came first.
                if let kept = self.tail(for: sessionId), Self.newestSeq(kept) < Self.newestSeq(tail) { remember(tail, for: sessionId) }
                return
            }
            if let stored, Self.newestSeq(stored) >= Self.newestSeq(tail) {
                hold(stored, for: sessionId)
            } else {
                remember(tail, for: sessionId)
            }
        }
    }

    /// The newest record's `seq` in `tail`; 0 when it has none.
    static func newestSeq(_ tail: JSONValue) -> Double {
        (tail["events"]?.arrayValue ?? []).compactMap { $0["seq"]?.doubleValue }.max() ?? 0
    }

    /// Returns, holding no thread, once the hand-overs made before this call are compared against
    /// the disk tier and saved.
    func settled() async {
        for comparison in Array(comparisons.values) { await comparison.value }
        await disk?.settled()
    }

    /// Forgets every tail: the session's chats are no longer this person's.
    public func clear() {
        generation &+= 1
        acceptsTails = false
        entries.removeAll()
        reads.removeAll()
        disk?.clear()
    }

    /// A new signed-in lifecycle may hand tails to the host again.
    public func resume() { acceptsTails = true }

    /// Whether `tail` is a page tail this keeps: records, not too many of them, and not too large.
    /// The byte bound is measured over the whole tail and not only its records, because the rest of
    /// it is not bounded by a record count — a chat's `queue` carries the full text of every
    /// prompt waiting to be sent, so a queued paste is what would grow this.
    nonisolated static func holds(_ tail: JSONValue) -> Bool {
        guard case .object(let fields) = tail, case .array(let events)? = fields["events"] else { return false }
        guard !events.isEmpty, events.count <= Self.events else { return false }
        var text = ""
        tail.appendCompactText(to: &text)
        return text.utf8.count <= Self.bytes
    }
}
