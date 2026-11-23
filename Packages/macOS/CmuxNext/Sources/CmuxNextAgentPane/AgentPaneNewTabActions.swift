import Foundation
public import CmuxNextActions
import CmuxNextCompat
public import CmuxNextPalette
public import CmuxNextWakeups

/// The Commands palette's actions as the New Tab page's bar lists them (``AgentPaneOmnibar/actions``), read on the
/// main thread's budgeted background work, a slice per task.
///
/// The bar lists every action the palette could run now, and reading each one's state (its title, why it cannot
/// run, its shortcut) takes 7-10 ms in all (PACING TRIAGE #32910: one main-thread task 95 ms after Cmd-T, in the
/// open's motion). No one sees the list until they type in the bar, so it is best-effort work: as Chrome's
/// scheduler runs best-effort tasks in the idle time each frame leaves, a ``FrameBatchQueue`` of the `background`
/// class reads ``slice`` of actions per task and yields to the person's input and to the frame's budget
/// (``MainFrameBudget``). It starts on the frame after the one that shows the page, never in the key's turn.
///
/// The list depends on the focus's context and on the registry, not on the page, so one is kept for each of the
/// last focus contexts (``kept``, ``keptContexts``): a page that shows while the list of its context holds takes
/// it with no read. What the kept list's key lacks (a state an
/// action's own rule reads) is read again at the person's first use of such a page (``read(wanted:_:)``).
///
/// ```swift
/// let actions = AgentPaneNewTabActions(on: mainWork, registry: registry) { palette.commandListing() }
/// actions.list(wanted: { !pages.isEmpty }) { listed in pages.forEach { $0.refreshNewTabActions(listed) } }
/// ```
@MainActor
public final class AgentPaneNewTabActions {
    /// How long one task reads: the background class's share of a frame (``MainFrameBudget/Budgets``).
    public static let slice: Duration = .microseconds(500)

    /// The actions and their JSON (the `actions` of an `acpmux-newtab-places` event), as one page takes them.
    public struct Listed: Sendable, Equatable {
        public var actions: [AgentPaneOmnibar.Action]
        public var json: String
    }

    /// What a list was read from, beyond each action's own state: the focus's context and the registry's changes.
    private struct Key: Equatable {
        var context: ActionContext
        var changes: Int
    }

    private let queue: FrameBatchQueue
    private let registry: ActionRegistry
    private let listing: @MainActor () -> PaletteCommandListing
    private let measure: @MainActor (() -> Void) -> Void
    private var running: PaletteCommandListing?
    /// Who waits for the list: each one's `wanted` (asked at the first task) and `deliver`.
    private var waiters: [(wanted: @MainActor () -> Bool, deliver: @MainActor (Listed) -> Void)] = []
    /// The last list read. A read that lists the same rows gives this value again (its array's buffer too), so a page
    /// that shows it compares equal at once and sends nothing, and its JSON is not encoded again.
    public private(set) var last: Listed?
    /// How many lists are kept, one for each focus context. In a hold of the New Tab key each new page's web view
    /// takes the keyboard after the page shows (2 contexts in turn), and the sidebar and a file preview each give
    /// one more while a page is open: 4. More contexts than that in turn is not a hold, and a kept list is a whole
    /// catalog of rows with its JSON, so the count is small and fixed.
    static let keptContexts = 4
    /// The kept lists, each with the key it holds for, in the order of their reads: the oldest is first and goes
    /// first. No two have the same context. Only a listing with a key is kept: one that saw two contexts or a change
    /// of the registry has none (a letter, then Return to a terminal while the letter's listing runs), and the next
    /// New Tab page still takes the list kept for its own context.
    private var keptLists: [(key: Key, listed: Listed)] = []
    /// The key of the listing being read; nil once it saw another context.
    private var readKey: Key?
    /// Changes of the registry's catalog, binds, keys and features since the lister was made, counted inside each
    /// change's own write (``watch()``): a page that shows in the turn of a change takes no older list.
    nonisolated private let changed = Atomic<Int>(0)
    private let tracking = SingleArmedTracking()
    private var queued = false
    /// A list is read to its end and waits for its hand-over (its JSON, then a frame).
    private var pending = false
    /// The queued first task reads the actions even while the kept list holds (``read(wanted:_:)``).
    private var fresh = false

    /// Whether a page that takes the list handed over now reads the actions again at its person's first use: the
    /// list is the kept one, read before these waiters asked, or its listing had no key (it saw two contexts or a
    /// change of the registry), or the focus's context or the registry changed while the list waited for its
    /// hand-over.
    public private(set) var firstUseReads = false
    /// One tracking of a web page's first input for each page model (``fill(again:_:)``), held while the model lives.
    let firstInputs = NSMapTable<AgentPaneModel, SingleArmedTracking>.weakToStrongObjects()

    /// What the lister did since it was made, as counts: the tests and the benches hold a page's cost by them.
    /// Two integers, each added to once for a listing.
    public struct Counts: Sendable, Equatable {
        /// Listings started: the first task of a read ran.
        public var started = 0
        /// Catalog actions whose state was read, over every listing read to its end (added when the read ends).
        public var actionsRead = 0
    }

    public private(set) var counts = Counts()

    /// - Parameters:
    ///   - work: The app's main-thread scheduler; the reads are one background ``FrameBatchQueue`` on it.
    ///   - registry: The palette's registry: its context and its changes are the kept list's key.
    ///   - measure: Runs each task (the app times it for its benches).
    ///   - listing: Starts one palette listing (``PaletteController/commandListing()``).
    public init(on work: MainWorkScheduler, registry: ActionRegistry, measure: @escaping @MainActor (() -> Void) -> Void = { $0() },
                listing: @escaping @MainActor () -> PaletteCommandListing) {
        queue = FrameBatchQueue(owner: "NewTab.paletteActions", budgeted: .background, on: work)
        self.registry = registry
        self.listing = listing
        self.measure = measure
    }

    /// The list that was read under the focus's context of now, while what it was read from holds: the registry's
    /// catalog, binds, keys and features did not change since its listing started. A page that shows takes it with
    /// no read. One list is kept for each of the last ``keptContexts`` contexts. A change of the registry ends each
    /// of them from inside the change's own write: no kept list has the new count in its key (``watch()``). The
    /// lists themselves go when the next list is kept (``keep(_:for:)``).
    public var kept: Listed? {
        let key = Key(context: registry.context, changes: changed.load(ordering: .relaxed))
        return keptLists.first { $0.key == key }?.listed
    }

    /// Keeps `listed` as the list of its key's context, the newest one, in place of that context's older list. Each
    /// list that was read before a change of the registry goes here (no request takes it: ``kept``). The oldest list
    /// goes when there are more than ``keptContexts``.
    private func keep(_ listed: Listed, for key: Key) {
        keptLists.removeAll { $0.key.context == key.context || $0.key.changes != key.changes }
        keptLists.append((key, listed))
        if keptLists.count > Self.keptContexts { keptLists.removeFirst() }
    }

    /// Gives the actions to `deliver`, when `wanted` still holds at the first task: the key's turn only queues it.
    /// While the kept list holds (``kept``) that task hands it over and reads nothing. Else the actions are listed in
    /// background tasks from the next frame on and handed over once read (their JSON is encoded off the main
    /// thread). A call while a list is read, or while a read one waits for its hand-over, joins it: every waiter gets
    /// the same list (the web pages' fill and each native page ask on their own).
    public func list(wanted: @escaping @MainActor () -> Bool, _ deliver: @escaping @MainActor (Listed) -> Void) {
        waiters.append((wanted, deliver))
        guard !pending, !queued, running == nil else { return }
        queued = true
        queue.enqueue { [weak self] in self?.start() }
    }

    /// ``list(wanted:_:)`` for a page's first use (its person typed in it or ran a row), when the page showed with
    /// the kept list: the actions are read again, never taken from the kept list, since an action's own rule can
    /// read a state that is no part of the kept list's key. It joins a listing that runs or waits for its hand-over.
    public func read(wanted: @escaping @MainActor () -> Bool, _ deliver: @escaping @MainActor (Listed) -> Void) {
        if !pending, running == nil { fresh = true }
        list(wanted: wanted, deliver)
    }

    /// The first task: the palette's context (the focused object) and catalog are read here, not in the key's turn.
    private func start() {
        queued = false
        let read = fresh
        fresh = false
        waiters.removeAll { !$0.wanted() }
        guard !waiters.isEmpty else { return }
        if !read, let kept { return hand(kept, readUnder: nil) }
        watch()
        readKey = Key(context: registry.context, changes: changed.load(ordering: .relaxed))
        measure { running = listing() }
        counts.started += 1
        queue.enqueue { [weak self] in self?.step() }
    }

    /// Counts the next change of what a row's face reads from the registry itself: the catalog, the binds, the
    /// keys and the features. One tracking armed at a time; the first listing after it fires arms it again.
    private func watch() {
        tracking.track(shape: []) {
            _ = (registry.descriptors, registry.actions, registry.shortcutOverrides, registry.chordOverrides,
                 registry.alternateShortcuts, registry.keyBindingLayers, registry.disabledFeatures)
        } onChange: { [weak self] in
            self?.changed.add(1, ordering: .relaxed)
        }
    }

    private func step() {
        guard let reading = running else { return }
        // The key's context is the one the first action is read under (the focus settles after the key's turn). A
        // listing that then sees another context mixes the rows of both: it is handed over as it is, and not kept.
        if reading.actionsRead == 0 { readKey?.context = registry.context } else if readKey?.context != registry.context { readKey = nil }
        var entries: [PaletteCommandEntry]?
        measure { entries = reading.step(until: .now + Self.slice) }
        guard let entries else { return queue.enqueue { [weak self] in self?.step() } }
        running = nil
        counts.actionsRead += reading.actionsRead
        let key = readKey?.changes == changed.load(ordering: .relaxed) ? readKey : nil
        let actions = entries.filter { AgentPaneOmnibar.Action.pageMayRun($0.id.rawValue) }.map(AgentPaneOmnibar.Action.init(paletteEntry:))
        // A request from now to the hand-over joins this list (`list(wanted:_:)`): it is not read again.
        pending = true
        if let last, last.actions == actions {
            if let key { keep(last, for: key) }
            return queue.enqueue { [weak self] in self?.hand(last, readUnder: key) }
        }
        // Best effort: only a person typing in the bar reads the list, and it takes the last one until this one comes.
        let json = Task.detached(priority: WorkPriority.bestEffort.taskPriority) { Self.encode(actions) }
        // task-owner: one hand-over per list.
        Task { @MainActor [weak self] in
            let encoded = await json.value
            guard let self else { return }
            let listed = Listed(actions: actions, json: encoded)
            last = listed
            if let key { keep(listed, for: key) }
            // The pages take it as background work too (P5): each one's event is a JSON encode and a script call.
            queue.enqueue { [weak self] in self?.hand(listed, readUnder: key) }
        }
    }

    /// Hands `listed` to each waiter. `key` is what it was read under: nil for a list with no key, and for the kept
    /// list. A page that takes the list reads again at its first use, unless the list has a key that still holds
    /// now: the focus's context and the registry did not change while the list waited for this hand-over.
    private func hand(_ listed: Listed, readUnder key: Key?) {
        pending = false
        firstUseReads = key != Key(context: registry.context, changes: changed.load(ordering: .relaxed))
        defer { firstUseReads = false }
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.deliver(listed) }
    }

    nonisolated static func encode(_ actions: [AgentPaneOmnibar.Action]) -> String {
        (try? JSONEncoder().encode(actions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

extension AgentPaneOmnibar.Action {
    /// Whether a New Tab page may list the palette action `id` (``AgentPaneOmnibar/actions``) and run it (`app.action`):
    /// never a Computer Use action (Set Up, Restart, the two grants, Stop, Focus, the saved approvals, cmux Remote's
    /// restart). `app.action` runs a listed row as the person's own pick with no gesture, and those turn Computer Use on,
    /// start a grant or restart its helper. Set Up keeps its own gesture-gated route (`action.run`,
    /// ``AgentPaneModel/setupActions``). By id, so a new Computer Use action is left out with no edit.
    public static func pageMayRun(_ id: String) -> Bool { !id.lowercased().contains("computeruse") }

    /// A Commands palette row as the bar lists it.
    public init(paletteEntry entry: PaletteCommandEntry) {
        self.init(id: entry.id.rawValue, title: entry.title, detail: entry.section, keywords: entry.keywords,
                  keycaps: entry.keycaps.isEmpty ? nil : entry.keycaps, symbol: entry.symbol)
    }
}
