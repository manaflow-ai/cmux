public import AppKit

/// The keys of one window's pending creations or awaited surface, in typing order.
@MainActor
public final class CreationInputBuffer {
    /// A ticket names its buffer too: a buffer flushed early never takes a later buffer's ticket of the same number.
    public struct Ticket: Hashable { fileprivate let id: Int; fileprivate let owner: ObjectIdentifier }

    /// The held keys in typing order, each with the creation it was typed for (its lane): the creation whose tab the
    /// focus named when the key was typed (the pane the person saw get the focus), nil for none. A key goes only to
    /// its own creation's terminal, never to another creation's (P0 1193: after Cmd-D, keys, Cmd-D, keys, the first
    /// new terminal ran the second one's keys while the second's focus was on its way).
    private var events: [(event: NSEvent, creation: Int?)] = []
    /// Each creation's provisional tab, kept after its reply: the terminal its lane goes to.
    private var laneTabs: [Int: String] = [:]
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
        if let tab { tabs[nextID] = tab; laneTabs[nextID] = tab }
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
            laneTabs[id] = nil
        }
        events.removeAll { $0.creation.map(ids.contains) ?? false }
        if pending.isEmpty, awaited.isEmpty { events.removeAll() }
        return true
    }

    /// Whether a creation of this hold still waits for its reply and shows `tab`.
    public func isCreating(tab: String) -> Bool { tabs.contains { $0.value == tab && pending[$0.key] != nil } }

    /// The pending creation whose new terminal view, tab `tab`, takes its own keys before the reply (its early view).
    public func earlyLane(tab: String) -> Int? { earlyTabs.filter { $0.value == tab }.map(\.key).max() }

    /// The lane of a key typed while the focus names (or is on its way to) tab `focusedTab`: the newest creation of
    /// this hold that shows that tab, nil when the focus names none of them (a key typed after the person moved on).
    public func lane(focusedTab: String?) -> Int? {
        guard let focusedTab else { return nil }
        return laneTabs.filter { $0.value == focusedTab }.map(\.key).max()
    }

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

    /// Holds `event`, typed while the focus named `focusedTab` (``lane(focusedTab:)``).
    public func capture(_ event: NSEvent, focusedTab: String?) { events.append((event, lane(focusedTab: focusedTab))) }

    /// Holds `earlier` (keys taken and not run yet, typed after the key that started the newest
    /// creation) before the keys held now, typed for that creation.
    public func prepend(_ earlier: ArraySlice<NSEvent>) {
        let creation = nextID > 0 ? nextID : nil
        events.insert(contentsOf: earlier.map { ($0, creation) }, at: 0)
    }

    public func take() -> [NSEvent] {
        defer { events.removeAll() }
        return events.map(\.event)
    }

    /// Takes the keys of lane `lane` only, in typing order (its early view has the keyboard); the others keep waiting.
    public func take(lane: Int) -> [NSEvent] {
        defer { events.removeAll { $0.creation == lane } }
        return events.filter { $0.creation == lane }.map(\.event)
    }

    /// Ends the hold. Each lane whose terminal is not the focused tab `focused` gets its keys as typed text through
    /// `writer(tab)` (that terminal's input, by the terminal id its creation chose, nil when no terminal of the window
    /// shows it), so a key never runs into another terminal than the one it was typed for. Returns the rest in typing
    /// order, to run again as typed: the focused lane's keys, keys of no lane, and any lane with a key that is not plain
    /// text (a chord runs only through the app's dispatch) or whose terminal is gone.
    public func take(focused: String?, writer: (String) -> (@MainActor (Data) -> Void)?) -> [NSEvent] {
        for (lane, tab) in laneTabs where tab != focused {
            let keys = events.filter { $0.creation == lane }.map(\.event)
            let text = keys.map(Self.typedText)
            guard !keys.isEmpty, !text.contains(nil), let write = writer(tab) else { continue }
            write(Data(text.compactMap { $0 }.joined().utf8))
            events.removeAll { $0.creation == lane }
        }
        return take()
    }

    /// What plain typing `event` sends to a terminal (its characters), nil for a Command chord or a function key (an
    /// arrow, F1): those run only through the app's dispatch.
    public static func typedText(_ event: NSEvent) -> String? {
        guard event.modifierFlags.isDisjoint(with: [.command, .function]), let text = event.characters, !text.isEmpty,
              !text.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return nil }
        return text
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
