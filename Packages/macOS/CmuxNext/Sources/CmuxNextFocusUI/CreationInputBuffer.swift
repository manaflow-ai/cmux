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
    /// The machine each creation's terminal is on (its daemon), when it was known at its start.
    private var laneMachines: [Int: String] = [:]
    /// How many lanes this hold took over from another hold (``prepend(_:issuer:)``).
    private var adopted = 0
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
    /// `machine`: the machine the creation's terminal is on (its keys reach it there when its view is gone).
    public func open(generation: UInt64, earlyTab: String? = nil, tab: String? = nil, machine: String? = nil) -> Ticket {
        nextID += 1
        pending[nextID] = generation
        if let earlyTab { earlyTabs[nextID] = earlyTab }
        if let tab { tabs[nextID] = tab; laneTabs[nextID] = tab; laneMachines[nextID] = machine }
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
            laneMachines[id] = nil
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

    /// Holds `earlier` (keys taken and not run yet, typed after the key that started the newest creation) before the
    /// keys held now. Each keeps the terminal it was typed for, also when it came from another hold: only the keys of
    /// `issuer`'s lane (the lane of the key that started the creation; nil: no lane) move to the new creation, as the
    /// person typed them after that lane's Cmd-D (P0 1193 follow-up: a key held for another terminal went to the split).
    public func prepend(_ earlier: [(event: NSEvent, lane: HeldLane?)], issuer: HeldLane?) {
        let creation = nextID > 0 ? nextID : nil
        let entries = earlier.map { key in (event: key.event, creation: key.lane == issuer ? creation : key.lane.map(adopt)) }
        events.insert(contentsOf: entries, at: 0)
    }

    /// The lane of this hold that delivers to `lane`'s terminal: one of its creations that shows that tab, else a lane
    /// it keeps only for keys carried over from another hold (a negative number, never a pending creation).
    private func adopt(_ lane: HeldLane) -> Int {
        if let id = laneTabs.first(where: { $0.value == lane.tab })?.key { return id }
        adopted += 1
        let id = -adopted
        laneTabs[id] = lane.tab
        laneMachines[id] = lane.machine
        return id
    }

    /// The terminal lane `id` delivers to; nil for no lane.
    private func heldLane(_ id: Int?) -> HeldLane? { id.flatMap { id in laneTabs[id].map { HeldLane(tab: $0, machine: laneMachines[id]) } } }

    public func take() -> [NSEvent] {
        defer { events.removeAll() }
        return events.map(\.event)
    }

    /// The terminal a lane's keys are for: its tab, and the machine it is on when that was known.
    public struct HeldLane: Hashable, Sendable {
        public let tab: String
        public let machine: String?
    }

    /// Held keys at the hold's end, in typing order (``take(focused:)``).
    public enum HeldKey {
        /// Keys of a lane whose terminal is not the focused one, typed one after another: that terminal types them
        /// with its own key encoding, never the focused terminal (a held Ctrl-C must not stop another process).
        case type([NSEvent], lane: HeldLane)
        /// A chord (Command or Control) typed for a lane whose terminal is not the focused one: an app shortcut (Cmd-D,
        /// Ctrl-`, Ctrl-Tab) runs with that terminal's tab as its target (as a key press there); any other chord
        /// (Ctrl-C) is that terminal's key.
        case command(NSEvent, lane: HeldLane)
        /// A key that runs again as typed: the focused lane's (`lane`), or a key typed for no creation (nil).
        case run(NSEvent, lane: HeldLane?)

        /// Each key with the terminal it was typed for, in order (to hold them again, ``prepend(_:issuer:)``).
        public var keys: [(event: NSEvent, lane: HeldLane?)] {
            switch self {
            case .type(let events, let lane): events.map { ($0, lane) }
            case .command(let event, let lane): [(event, lane)]
            case .run(let event, let lane): [(event, lane)]
            }
        }

        /// The terminal the first key was typed for.
        public var lane: HeldLane? { keys.first?.lane }
    }

    /// Takes the keys of lane `lane` only, in typing order, to run again as typed (its early view has the keyboard);
    /// the others keep waiting.
    public func take(lane: Int) -> [HeldKey] {
        defer { events.removeAll { $0.creation == lane } }
        return events.filter { $0.creation == lane }.map { .run($0.event, lane: heldLane(lane)) }
    }

    /// Ends the hold: every held key in typing order, each for its own terminal while the focus is on tab `focused`.
    public func take(focused: String?) -> [HeldKey] {
        var keys: [HeldKey] = []
        for (event, id) in events {
            guard let lane = heldLane(id), lane.tab != focused else {
                keys.append(.run(event, lane: heldLane(id)))
                continue
            }
            if !event.modifierFlags.isDisjoint(with: [.command, .control]) {
                keys.append(.command(event, lane: lane))
            } else if case .type(let earlier, let last)? = keys.last, last == lane {
                keys[keys.count - 1] = .type(earlier + [event], lane: lane)
            } else {
                keys.append(.type([event], lane: lane))
            }
        }
        events.removeAll()
        return keys
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
