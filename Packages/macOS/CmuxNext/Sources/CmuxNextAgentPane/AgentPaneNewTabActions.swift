import Foundation
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
/// ```swift
/// let actions = AgentPaneNewTabActions(on: mainWork) { palette.commandListing() }
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

    private let queue: FrameBatchQueue
    private let listing: @MainActor () -> PaletteCommandListing
    private let measure: @MainActor (() -> Void) -> Void
    private var running: PaletteCommandListing?
    /// Who waits for the list being read: each one's `wanted` (asked at the first task) and `deliver`.
    private var waiters: [(wanted: @MainActor () -> Bool, deliver: @MainActor (Listed) -> Void)] = []
    /// The last list read. A read that lists the same rows gives this value again (its array's buffer too), so a page
    /// that shows it compares equal at once and sends nothing, and its JSON is not encoded again.
    public private(set) var last: Listed?
    private var encoding = 0

    /// - Parameters:
    ///   - work: The app's main-thread scheduler; the reads are one background ``FrameBatchQueue`` on it.
    ///   - measure: Runs each task (the app times it for its benches).
    ///   - listing: Starts one palette listing (``PaletteController/commandListing()``).
    public init(on work: MainWorkScheduler, measure: @escaping @MainActor (() -> Void) -> Void = { $0() },
                listing: @escaping @MainActor () -> PaletteCommandListing) {
        queue = FrameBatchQueue(owner: "NewTab.paletteActions", budgeted: .background, on: work)
        self.listing = listing
        self.measure = measure
    }

    /// Lists the actions in background tasks from the next frame on and gives them to `deliver` once read (their
    /// JSON is encoded off the main thread), when `wanted` still holds at the first task: the key's turn only queues
    /// it. A call while a list is read joins it: every waiter whose `wanted` held gets the same list (the web pages'
    /// fill and each native page ask on their own).
    public func list(wanted: @escaping @MainActor () -> Bool, _ deliver: @escaping @MainActor (Listed) -> Void) {
        waiters.append((wanted, deliver))
        encoding &+= 1 // a list being encoded is older than this request
        guard !queued, running == nil else { return }
        queued = true
        queue.enqueue { [weak self] in self?.start() }
    }

    private var queued = false

    /// A native New Tab page's ask for the actions (``NativeNewTabModel/PaletteActionsRequest``): one waiter of the listing.
    public var request: NativeNewTabModel.PaletteActionsRequest {
        { [weak self] wanted, deliver in self?.list(wanted: wanted) { deliver($0.actions) } }
    }

    /// The first task: the palette's context (the focused object) and catalog are read here, not in the key's turn.
    private func start() {
        queued = false
        waiters.removeAll { !$0.wanted() }
        guard !waiters.isEmpty else { return }
        measure { running = listing() }
        queue.enqueue { [weak self] in self?.step() }
    }

    private func step() {
        guard let reading = running else { return }
        var entries: [PaletteCommandEntry]?
        measure { entries = reading.step(until: .now + Self.slice) }
        guard let entries else { return queue.enqueue { [weak self] in self?.step() } }
        running = nil
        let actions = entries.map(AgentPaneOmnibar.Action.init(paletteEntry:))
        encoding &+= 1
        let generation = encoding
        if let last, last.actions == actions {
            return queue.enqueue { [weak self] in
                guard let self, generation == self.encoding else { return }
                hand(last)
            }
        }
        // Best effort: only a person typing in the bar reads the list, and it takes the last one until this one comes.
        let json = Task.detached(priority: WorkPriority.bestEffort.taskPriority) { Self.encode(actions) }
        // task-owner: one hand-over per list; a newer list or request (generation) drops it.
        Task { @MainActor [weak self] in
            let encoded = await json.value
            guard let self, generation == self.encoding else { return }
            let listed = Listed(actions: actions, json: encoded)
            last = listed
            // The pages take it as background work too (P5): each one's event is a JSON encode and a script call.
            queue.enqueue { [weak self] in
                guard let self, generation == self.encoding else { return }
                hand(listed)
            }
        }
    }

    private func hand(_ listed: Listed) {
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.deliver(listed) }
    }

    nonisolated static func encode(_ actions: [AgentPaneOmnibar.Action]) -> String {
        (try? JSONEncoder().encode(actions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

extension AgentPaneOmnibar.Action {
    /// A Commands palette row as the bar lists it.
    public init(paletteEntry entry: PaletteCommandEntry) {
        self.init(id: entry.id.rawValue, title: entry.title, detail: entry.section, keywords: entry.keywords,
                  keycaps: entry.keycaps.isEmpty ? nil : entry.keycaps)
    }
}
