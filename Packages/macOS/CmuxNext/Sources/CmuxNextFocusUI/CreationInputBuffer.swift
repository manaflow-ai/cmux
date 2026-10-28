public import AppKit

/// The keys of one window's pending creations or awaited surface, in typing order.
@MainActor
public final class CreationInputBuffer {
    /// A ticket names its buffer too: a buffer flushed early never takes a later buffer's ticket of the same number.
    public struct Ticket: Hashable { fileprivate let id: Int; fileprivate let owner: ObjectIdentifier }

    /// The held keys in typing order, each with the creation it was typed for: the newest one
    /// pending when it was typed (the pane the person saw get the focus), nil for none.
    private var events: [(event: NSEvent, creation: Int?)] = []
    private var pending: [Int: UInt64] = [:]
    private var awaited: Set<UInt64> = []
    /// Pending creations whose new terminal's view takes keys before the reply, by its tab id.
    private var earlyTabs: [Int: String] = [:]
    /// Pending creations' provisional tabs, by ticket.
    private var tabs: [Int: String] = [:]
    private var nextID = 0
    /// When the hold began.
    public let began: ContinuousClock.Instant
    /// When the last pending creation got its reply: the hold's limit counts from here.
    private var repliedAt: ContinuousClock.Instant?

    public init(began: ContinuousClock.Instant) { self.began = began }

    public var isResolved: Bool { pending.isEmpty }
    /// A creation opened in this hold: only its reply (or the request timeout) ends it.
    public var holdsCreation: Bool { nextID > 0 }
    /// A creation of this hold still waits for its reply: until then its keys never expire.
    public var hasPendingCreation: Bool { !pending.isEmpty }
    public var isEmpty: Bool { events.isEmpty }
    /// How many creations this hold opened: a key run again that opened another one changes it.
    public var openedCount: Int { nextID }

    /// `earlyTab`: the tab of the new terminal's view when that view takes keys before the reply
    /// (its keys reach the daemon by terminal id, which queues them, cx-wb5.78).
    /// `tab`: the provisional tab the creation shows, so a close of it can cancel the hold (`cancel(tab:)`).
    public func open(generation: UInt64, earlyTab: String? = nil, tab: String? = nil) -> Ticket {
        nextID += 1
        pending[nextID] = generation
        if let earlyTab { earlyTabs[nextID] = earlyTab }
        if let tab { tabs[nextID] = tab }
        return Ticket(id: nextID, owner: ObjectIdentifier(self))
    }

    /// The person closed the creation of `tab` before it existed: it waits for nothing more, and
    /// the keys typed for it are dropped with it (never given to another tab). Keys typed for
    /// another creation of this hold keep waiting for it, in order. False when no pending creation
    /// shows `tab`.
    public func cancel(tab: String) -> Bool {
        let ids = Set(tabs.filter { $0.value == tab }.map(\.key))
        guard !ids.isEmpty else { return false }
        for id in ids {
            tabs[id] = nil
            earlyTabs[id] = nil
            pending[id] = nil
        }
        events.removeAll { $0.creation.map(ids.contains) ?? false }
        if pending.isEmpty, awaited.isEmpty { events.removeAll() }
        return true
    }

    /// Whether a creation of this hold still waits for its reply and shows `tab`.
    public func isCreating(tab: String) -> Bool { tabs.contains { $0.value == tab && pending[$0.key] != nil } }

    /// Whether a pending creation's new terminal view, tab `tab`, takes keys now.
    public func takesKeysEarly(tab: String) -> Bool { earlyTabs.values.contains(tab) }

    /// `awaitsFocus`: the creation asked for focus under its generation; the keys wait until that
    /// expectation landed or was replaced. A failed creation asked for nothing.
    public func resolve(_ ticket: Ticket, awaitsFocus: Bool) {
        guard ticket.owner == ObjectIdentifier(self) else { return }
        earlyTabs[ticket.id] = nil
        tabs[ticket.id] = nil
        guard let generation = pending.removeValue(forKey: ticket.id) else { return }
        if pending.isEmpty { repliedAt = ContinuousClock.now }
        if awaitsFocus { awaited.insert(generation) }
    }

    public func awaits(_ generation: UInt64) -> Bool { awaited.contains(generation) }

    /// Holds `event`, typed for the newest pending creation.
    public func capture(_ event: NSEvent) { events.append((event, pending.keys.max())) }

    /// Holds `earlier` (keys taken and not run yet, typed after the key that started the newest
    /// pending creation) before the keys held now, typed for that creation.
    public func prepend(_ earlier: ArraySlice<NSEvent>) {
        let creation = pending.keys.max()
        events.insert(contentsOf: earlier.map { ($0, creation) }, at: 0)
    }

    public func take() -> [NSEvent] {
        defer { events.removeAll() }
        return events.map(\.event)
    }

    /// Calls `expired` after `limit` unless a creation of this hold still waits for its reply then
    /// (its reply arms the bound again: the coordinator calls this from `resolve`).
    public func expire(after limit: Duration, _ expired: @escaping @MainActor (CreationInputBuffer) -> Void) {
        // task-owner: one-shot bound on this hold; a hold that ended first makes it a no-op
        Task { @MainActor [weak self] in
            // wakeup-allow: one-shot bound on a key hold, so a hold whose terminal never shows ends
            try? await Task.sleep(for: limit)
            guard let self, !hasPendingCreation else { return }
            expired(self)
        }
    }

    /// Whether this hold keeps `event`.
    ///
    /// - A close key (`closes`: its binding is a close action, Cmd-W) never waits: it acts at once on
    ///   what it closes, a pending creation included (TabLifecycle cancels it). Held, it ran later
    ///   with the other held keys and closed the next tab, then the window (macOS 15 tester,
    ///   2026-10-19: Cmd-D then Cmd-W from Settings).
    /// - A creation waiting for its reply keeps every other key.
    /// - After the reply the hold ends `limit` later (`expiring`), even when the focus it asked for
    ///   never lands (a split from a page tab shows a New Tab page, not a terminal).
    /// - A hold that only waits for a selected terminal's surface ends `limit` after it began, and
    ///   lets a chord through while it holds nothing (held Ctrl-Tab makes no surface for a tab it passed).
    public func holds(_ event: NSEvent, limit: Duration, expiring: Bool, closes: Bool = false) -> Bool {
        if closes { return false }
        guard !hasPendingCreation else { return true }
        if expiring, ContinuousClock.now - (repliedAt ?? began) >= limit { return false }
        if holdsCreation { return true }
        return !(isEmpty && !event.modifierFlags.intersection([.command, .control]).isEmpty)
    }
}
