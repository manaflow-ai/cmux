public import AppKit
import os

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
    /// Every tab a creation of this hold shows, replied or not, for the hold's lifetime (``keepsKeysFromLeftPage``).
    private var madeTabs: Set<String> = []
    /// Creations that make a new workspace with its terminal (`open(…, newWorkspace: true)`), by ticket, until they
    /// fail. The keys typed for one are that terminal's: they never go to anything else (an agent's message box).
    private var workspaceTickets: Set<Int> = []
    /// The workspace each of them made, once its reply came.
    private var madeWorkspaces: [Int: String] = [:]
    /// The new workspaces the person moved on from (``personMovedOn()``): their keys typed before it still wait for them.
    private var movedOnFrom: Set<Int> = []
    /// The new workspaces whose create failed: over, they hold nothing of the person's (``personLeftEveryCreation``).
    private var failedWorkspaces: Set<Int> = []
    /// The focus generation (the person's newest intent) the newest creation of this hold was asked under.
    public private(set) var newestGeneration: UInt64?
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
    /// `newWorkspace`: the creation makes a new workspace with its terminal; the keys typed for it wait until the window
    /// shows that workspace with its terminal, also after the person left it (``shownWorkspaceToWaitFor``,
    /// ``leftWorkspaceWithKeys``), and are dropped when it fails or has not shown by the hold's limit
    /// (``resolve(_:awaitsFocus:workspace:)``, ``dropKeys(ofWorkspacesOtherThan:)``).
    public func open(generation: UInt64, earlyTab: String? = nil, tab: String? = nil, machine: String? = nil, newWorkspace: Bool = false) -> Ticket {
        nextID += 1
        pending[nextID] = generation
        newestGeneration = generation
        if newWorkspace { workspaceTickets.insert(nextID) }
        if let earlyTab { earlyTabs[nextID] = earlyTab }
        if let tab { tabs[nextID] = tab; laneTabs[nextID] = tab; laneMachines[nextID] = machine }
        if let tab { madeTabs.insert(tab) }
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
        // Nothing waits any more: a key with no terminal of its own (no lane, or a lane with no tab) goes with the close,
        // never into whatever has the focus; a key carried for another terminal stays, to go to it at the hold's end.
        if pending.isEmpty, awaited.isEmpty { events.removeAll { $0.creation.flatMap { laneTabs[$0] } == nil && !isOpenClose($0.creation) } }
        return true
    }

    /// Pending closes of the focused terminal, by ticket: the closing tabs (the one focused at the Cmd-W first). A person's
    /// Cmd-W on a live terminal first waits for an answer (the close warning's daemon read), and that terminal keeps the
    /// focus meanwhile. A key typed then is the close's (its lane), never the closing terminal's: it goes where the focus
    /// is once the close ran, or to that terminal when the person cancels the close (P0 close-then-type: the first key
    /// after Cmd-W went into the closing terminal).
    private var closingTabs: [Int: [String]] = [:]

    /// Opens a pending close of tabs `closing` (the focused terminal's first, on `machine`): keys typed while the focus
    /// names one of them are its own.
    /// `takesEveryKey`: the close took its tabs out of the strip while it reads (the focus moved to a neighbour the
    /// person did not pick): every key typed in the window until it answers is the close's, whatever has the focus.
    public func openClose(closing: [String], machine: String?, takesEveryKey: Bool = false) -> Ticket {
        let ticket = open(generation: 0)
        closingTabs[ticket.id] = closing
        laneMachines[ticket.id] = machine
        if takesEveryKey { everyKeyCloses.insert(ticket.id) }
        return ticket
    }

    /// Closes that take every key of the window while they read (``openClose(closing:machine:takesEveryKey:)``).
    private var everyKeyCloses: Set<Int> = []

    /// Closes whose question asks the person (``parkClose(_:)``), by ticket: the tabs each closes. Their keys stay here, in
    /// typing order with every other held key of the window, until the answer names their terminal (``settleClose``).
    private var answering: [Int: [String]] = [:]

    /// Whether lane `id` is a close that still reads or asks: its keys have no terminal yet.
    private func isOpenClose(_ id: Int?) -> Bool { id.map { closingTabs[$0] != nil || answering[$0] != nil } ?? false }

    /// Whether a close of this hold still waits for its answer and closes `tab`, or takes every key of the window
    /// (a hidden close: the focus moved to a neighbour that `tab` may be).
    public func isClosing(tab: String?) -> Bool {
        everyKeyCloses.contains { closingTabs[$0] != nil } || tab.map { tab in closingTabs.values.contains { $0.contains(tab) } } == true
    }

    /// The close behind `ticket` ran, stopped or was answered: its keys are tab `tab`'s (the focused terminal's after the
    /// close), on `machine`; nil `tab` runs them as typed, in whatever has the focus then. A closing tab itself (the focus
    /// has not left it yet) gets no lane: its keys run as typed. `stays`: the person cancelled the close's question, and its
    /// keys go to the terminal it asked about (the one focused at the Cmd-W).
    /// A close that ends with no question while another close still reads or asks (two quick Cmd-Ws): its keys become that
    /// close's; a question answered Close while another close still reads: that close's. Cancel never hands them on. Every
    /// key keeps its place in the window's one typing order, whichever close answers first.
    public func settleClose(_ ticket: Ticket, keysTo tab: String?, stays: Bool = false, machine: String?) {
        guard ticket.owner == ObjectIdentifier(self) else { return }
        let answered = answering.removeValue(forKey: ticket.id)
        guard let closing = closingTabs.removeValue(forKey: ticket.id) ?? answered else { return }
        everyKeyCloses.remove(ticket.id)
        if !stays, let next = Set(closingTabs.keys).union(answered == nil ? Array(answering.keys) : []).max() {
            events = events.map { $0.creation == ticket.id ? ($0.event, next) : $0 }
            return resolve(ticket, awaitsFocus: false)
        }
        if stays { laneTabs[ticket.id] = closing.first } else { (laneTabs[ticket.id], laneMachines[ticket.id]) = (tab.flatMap { closing.contains($0) ? nil : $0 }, machine) }
        resolve(ticket, awaitsFocus: false)
    }

    /// The close behind `ticket` asks the person first: it waits for nothing more here, and its keys stay held, in typing
    /// order, until the answer (``settleClose(_:keysTo:stays:machine:)``). The window's keys meanwhile are the question's.
    public func parkClose(_ ticket: Ticket) {
        guard ticket.owner == ObjectIdentifier(self), let closing = closingTabs.removeValue(forKey: ticket.id) else { return }
        everyKeyCloses.remove(ticket.id)
        answering[ticket.id] = closing
        resolve(ticket, awaitsFocus: false)
    }

    /// A close whose question asks the person (``parkClose(_:)``); nil `ticket`: it holds no keys.
    public struct ParkedClose {
        public let ticket: Ticket?
        public init(ticket: Ticket?) { self.ticket = ticket }
    }

    /// Whether a creation of this hold still waits for its reply and shows `tab`.
    public func isCreating(tab: String) -> Bool { tabs.contains { $0.value == tab && pending[$0.key] != nil } }

    /// The pending creation whose new terminal view, tab `tab`, takes its own keys before the reply (its early view).
    public func earlyLane(tab: String) -> Int? { earlyTabs.filter { $0.value == tab }.map(\.key).max() }

    /// The lane of a key typed while the focus names (or is on its way to) tab `focusedTab`: the newest creation of
    /// this hold that shows that tab, nil when the focus names none of them (a key typed after the person moved on).
    public func lane(focusedTab: String?) -> Int? {
        if let close = everyKeyCloses.filter({ closingTabs[$0] != nil }).max() { return close }
        guard let focusedTab else { return nil }
        if let close = closingTabs.filter({ $0.value.contains(focusedTab) }).map(\.key).max() { return close }
        return laneTabs.filter { $0.value == focusedTab }.map(\.key).max()
    }

    /// `awaitsFocus`: the creation asked for focus under its generation; the keys wait until that
    /// expectation landed or was replaced. A failed creation asked for nothing.
    /// `workspace`: the workspace a new-workspace creation made (nil: it made none). A new-workspace creation that failed
    /// takes the keys typed for its terminal with it: they never go to whatever has the focus instead.
    public func resolve(_ ticket: Ticket, awaitsFocus: Bool, workspace: String? = nil) {
        guard ticket.owner == ObjectIdentifier(self) else { return }
        earlyTabs[ticket.id] = nil
        tabs[ticket.id] = nil
        guard let generation = pending.removeValue(forKey: ticket.id) else { return }
        if pending.isEmpty { repliedAt = ContinuousClock.now }
        if awaitsFocus { awaited.insert(generation) }
        guard workspaceTickets.contains(ticket.id) else { return }
        if awaitsFocus, let workspace {
            madeWorkspaces[ticket.id] = workspace
        } else {
            workspaceTickets.remove(ticket.id)
            failedWorkspaces.insert(ticket.id) // released at once: it keeps no later key waiting (review of #32148)
            let before = events.count
            events.removeAll { $0.creation == ticket.id }
            Self.logDropped(before - events.count, why: "its create failed")
        }
    }

    /// The workspace the newest new-workspace creation of this hold made: the window shows it before the keys go on.
    /// Nil when the hold has none, or its reply has not come (``hasPendingCreation`` holds the keys then).
    public var awaitedWorkspace: String? { workspaceTickets.max().flatMap { madeWorkspaces[$0] } }

    /// The workspace every held key waits to see shown: ``awaitedWorkspace`` unless the person left it (``personMovedOn()``).
    /// A left workspace keeps no other key waiting (review of #32148): only its own keys wait (``leftWorkspaceWithKeys``).
    public var shownWorkspaceToWaitFor: String? { workspaceTickets.subtracting(movedOnFrom).max().flatMap { madeWorkspaces[$0] } }

    /// A new workspace the person left that replied and still holds keys typed for it before they left: those keys alone
    /// wait for the window to show it with its terminal, or the hold's limit; the other lanes' keys go on (review of #32352:
    /// the store shows a new workspace a frame after the create's reply, and the keys were dropped in the reply's turn).
    public var leftWorkspaceWithKeys: (ticket: Int, workspace: String)? {
        let held = Set(events.compactMap(\.creation))
        return workspaceTickets.intersection(movedOnFrom).intersection(held).max().flatMap { id in madeWorkspaces[id].map { (id, $0) } }
    }

    /// The creation whose keys alone keep waiting (``leftWorkspaceWithKeys``) while the window shows `shown` and its
    /// terminal has the keyboard there or not (`terminalReady`); nil when no left workspace's keys wait any more, or when
    /// the window shows the workspace the person did not leave (``shownWorkspaceToWaitFor``): the hold ends there, and the
    /// left one's keys go with it as before (review of #32352: keys typed into that shown workspace waited up to 2 s).
    public func keysKeptForLeftWorkspace(shown: String?, terminalReady: Bool) -> Int? {
        if let current = shownWorkspaceToWaitFor, current == shown { return nil }
        guard let left = leftWorkspaceWithKeys, left.workspace != shown || !terminalReady else { return nil }
        return left.ticket
    }

    /// Whether a creation of this hold, asked under the person's newest intent `generation`, keeps the window's keyboard.
    public func ownsKeyboard(generation: UInt64) -> Bool { holdsCreation && newestGeneration == generation }

    /// Whether the page the person left keeps no keys (P0 INVERSE-KEY): the focus is on its way to another tab
    /// (`awaitsOtherTab`) and a creation of this hold, asked under their newest intent `generation`, owns the keyboard.
    /// The focused tab `focusedTab` is never one this hold makes, before or after its reply (a new browser tab's own
    /// page takes the keys).
    public func keepsKeysFromLeftPage(awaitsOtherTab: Bool, generation: UInt64, focusedTab: String?) -> Bool {
        awaitsOtherTab && ownsKeyboard(generation: generation) && focusedTab.map { !madeTabs.contains($0) } != false
    }

    /// The person acted after asking for this hold's new workspaces (a click, even on the view that already had the focus,
    /// which moves no focus generation; one of their actions): the keys typed from now on are no longer those workspaces'
    /// (review of #32098: they took the new workspace's lane and were dropped when it never showed). Keys held for them
    /// before it still wait for them to show (``leftWorkspaceWithKeys``); no other key waits for them.
    public func personMovedOn() {
        guard !workspaceTickets.isEmpty else { return }
        movedOnFrom.formUnion(workspaceTickets)
        newestGeneration = nil
    }

    /// Every creation of this hold is a new workspace the person moved on from (``personMovedOn()``) or one whose create
    /// failed: a focused terminal still to show takes the keys typed now in its own lane, as with no hold (REOPEN-F4, review
    /// of #32148). A failed one alone is not enough: until the person acts, their claim keeps the keys.
    public var personLeftEveryCreation: Bool { !movedOnFrom.isEmpty && movedOnFrom.union(failedWorkspaces).count == nextID }

    /// Whether a key typed now with the focus on `focusedTab` goes on to the view at once: the person moved on from every
    /// creation of this hold (new workspaces only), the key is for no creation's or surface's terminal, and no key that
    /// runs as typed waits before it (their order).
    public func passesOn(focusedTab: String?) -> Bool {
        guard personLeftEveryCreation, !awaitsPage, lane(focusedTab: focusedTab) == nil else { return false } // a page to show keeps it
        return !events.contains { $0.creation == nil }
    }

    /// The keys held for a new workspace's terminal (no terminal lane yet) go into `tab` on `machine`: once the window
    /// shows the workspace they run in that terminal, never in what has the keyboard instead (Home's message box beside
    /// the pinned dock). With no terminal found (nil) they are dropped, as for a workspace that never showed.
    public func bindNewWorkspaceKeys(to tab: String?, machine: String?) {
        let unbound = workspaceTickets.filter { laneTabs[$0] == nil }
        guard let tab else {
            let before = events.count
            events.removeAll { $0.creation.map(unbound.contains) ?? false }
            return Self.logDropped(before - events.count, why: "its workspace shows no terminal")
        }
        for id in unbound { (laneTabs[id], laneMachines[id]) = (tab, machine) }
    }

    /// Drops the held keys typed for a new workspace's terminal that the window does not show (`shown`: the workspace it
    /// shows now): still on its way, or never shown. They are never run into what has the focus instead (Home's Chief
    /// message box: dogfood v2.2.3, terminal input must never reach an agent). True when it dropped a creation's keys.
    public func dropKeys(ofWorkspacesOtherThan shown: String?) -> Bool {
        let unshown = workspaceTickets.filter { madeWorkspaces[$0] == nil || madeWorkspaces[$0] != shown }
        guard !unshown.isEmpty else { return false }
        let before = events.count
        events.removeAll { $0.creation.map(unshown.contains) ?? false }
        Self.logDropped(before - events.count, why: "the window never showed its workspace")
        workspaceTickets.subtract(unshown)
        return true
    }

    /// Held keys of a new workspace's terminal that never run: the log says how many and why.
    private static func logDropped(_ count: Int, why: String) {
        guard count > 0 else { return }
        Logger(subsystem: "com.cmuxterm.app.next", category: "focus.creation-hold")
            .notice("\(count, privacy: .public) key(s) typed for a new workspace's terminal dropped: \(why, privacy: .public)")
    }

    public func awaits(_ generation: UInt64) -> Bool { awaited.contains(generation) }

    /// Holds `event`, typed while the focus named `focusedTab` (``lane(focusedTab:)``). A key typed for no creation's tab
    /// while a new workspace's terminal is on its way and the person has not moved on (`forNewWorkspace`) is that
    /// terminal's: its keys wait for the window to show it. An adopted lane (a cold terminal's surface hold, keys carried
    /// from another hold) is the terminal the person typed into before they asked for the workspace: it gives way to it.
    public func capture(_ event: NSEvent, focusedTab: String?, forNewWorkspace: Bool = false) {
        let workspace = forNewWorkspace ? workspaceTickets.subtracting(movedOnFrom).max() : nil // never one the person left
        let own = lane(focusedTab: focusedTab).flatMap { $0 < 0 && workspace != nil ? nil : $0 }
        events.append((event, own ?? workspace))
    }

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

    /// The focused terminal this hold waits to show (``awaitSurface(of:)``); nil for a creation's hold.
    public private(set) var awaitedTab: String?

    /// The hold waits for the surface of `lane`'s terminal, which the focus names before it shows (a reopened
    /// window, a workspace shown cold): keys typed while the focus names it are its own, and go to that terminal
    /// at the hold's end even when its view never came (by the daemon), never to another one (REOPEN-F4).
    public func awaitSurface(of lane: HeldLane) {
        awaitedTab = lane.tab
        _ = adopt(lane)
    }

    /// The hold waits for a focused page whose content is not made yet (a restored Chromium tab): every key but a close
    /// waits, with no terminal lane, and runs again as typed once it shows (REOPEN-F4 browser case).
    public private(set) var awaitsPage = false

    /// The hold waits for `content` (``AwaitedContent``): a terminal by its lane on `machine`, a page with no lane.
    public func awaitContent(_ content: AwaitedContent, machine: String?) {
        guard content.hasTerminalLane else { (awaitedTab, awaitsPage) = (content.tab, true); return }
        awaitSurface(of: HeldLane(tab: content.tab, machine: machine))
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
        public init(tab: String, machine: String?) { self.tab = tab; self.machine = machine }
    }

    /// Held keys at the hold's end, in typing order (``take(focused:)``).
    public enum HeldKey {
        /// Keys of a lane whose terminal is not the focused one, in order, typed as one run (one daemon send when its
        /// view is gone, so no key passes another): that terminal's own key encoding, never the focused terminal (a held
        /// Ctrl-C must not stop another process). Chords that are no app shortcut (Ctrl-C, Ctrl-U) stay in the run.
        case type([NSEvent], lane: HeldLane)
        /// An app shortcut (Cmd-D, Ctrl-`, Ctrl-Tab) typed for a lane whose terminal is not the focused one: it runs with
        /// that terminal's tab as its target, as a key press there.
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
    /// `isShortcut(event, tab)`: whether `event` runs an app shortcut in tab `tab`'s context.
    /// `keeping`: a creation whose keys stay held (a left workspace still to show, ``leftWorkspaceWithKeys``).
    public func take(focused: String?, keeping kept: Int? = nil, isShortcut: (NSEvent, String) -> Bool) -> [HeldKey] {
        var keys: [HeldKey] = []
        for (event, id) in events where kept == nil || id != kept {
            guard let lane = heldLane(id), lane.tab != focused else {
                keys.append(.run(event, lane: heldLane(id)))
                continue
            }
            if !event.modifierFlags.isDisjoint(with: [.command, .control]), isShortcut(event, lane.tab) {
                keys.append(.command(event, lane: lane))
            } else if case .type(let earlier, let last)? = keys.last, last == lane {
                keys[keys.count - 1] = .type(earlier + [event], lane: lane)
            } else {
                keys.append(.type([event], lane: lane))
            }
        }
        events.removeAll { kept == nil || $0.creation != kept }
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
