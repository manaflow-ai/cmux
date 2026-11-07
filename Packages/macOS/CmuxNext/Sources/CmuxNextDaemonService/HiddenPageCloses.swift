public import CmuxNextDaemon
public import CmuxNextLayout
import CmuxNextCompat
import CmuxNextWakeups

/// Tabs a person closed whose page decides the close (a live Chromium page runs its beforeunload
/// first, `BrowserUserClosing`): they leave their strip in the click's turn, and a pane whose last tab
/// that was leaves its window then too, as Chrome takes a closing tab away at once. The page stays
/// alive while Chromium decides: the hide is a close intent nothing sends (``HiddenTabClose``), and the
/// store keeps listing the tab for its gone-tab watchers. Leo 2026-11-03: "it's nigh instant for claude
/// and codex so we nede to be at least as fast"; 2026-10-25: a close never waits for the tab's close.
///
/// The page's own close (no handler, or Leave) lifts the hide in the turn its close takes the tab out
/// again (``lift(_:)``, no flash). A page that asks (beforeunload's "Leave site?") brings its tab back
/// in place, selected, before the question (``restore(_:)``). A page
/// that has neither closed nor asked by ``deadline`` is closed without asking (`timedOut`): the close took
/// effect on the click, so its tab never comes back unasked. `Pane` is the pane controller (compared by identity).
@MainActor
public final class HiddenPageCloses<Pane: AnyObject> {
    /// One hidden tab: its surface, and whether its page asks the person now (nil: no page to watch).
    public typealias Tab = (id: String, surface: SurfaceID, asks: (@MainActor @Sendable () -> Bool)?)

    private struct Entry {
        let hide: HiddenTabClose
        /// Held: the layout lets go of an emptied pane's controller once its close lands, and the page may still ask.
        let pane: Pane
        let asks: (@MainActor @Sendable () -> Bool)?
        let watch: Task<Void, Never>?
        let timer: DemandTimer
        func end() { watch?.cancel(); timer.cancel() }
    }

    private var entries: [String: Entry] = [:]
    /// The pane closes these hides showed, by pane: each ends with its pane's last hidden tab.
    private var paneCloses: [ObjectIdentifier: PendingPaneClose] = [:]
    private let hidden: @MainActor (Pane) -> PendingPaneClose?
    private let lifted: @MainActor (Pane, PendingPaneClose) -> Void
    private let restored: @MainActor (Pane, PendingPaneClose?, String) -> Void
    private let timedOut: @MainActor (Pane, String) -> Void

    /// How long a hidden tab waits for its page to close or ask before it closes without asking.
    public var deadline: Duration = .seconds(5)

    /// - Parameter hidden: Shows a pane's tabs left; returns the pane's close when no tab is left.
    /// - Parameter lifted: A pane's close yields to the close its last hidden tab's page started.
    /// - Parameter restored: A tab comes back: the pane's close (if any) is taken back, the tab selected.
    /// - Parameter timedOut: A tab whose page did not decide by ``deadline`` closes now, without asking (its hide lifted).
    public init(hidden: @escaping @MainActor (Pane) -> PendingPaneClose?, lifted: @escaping @MainActor (Pane, PendingPaneClose) -> Void,
                restored: @escaping @MainActor (Pane, PendingPaneClose?, String) -> Void,
                timedOut: @escaping @MainActor (Pane, String) -> Void) {
        self.hidden = hidden
        self.lifted = lifted
        self.restored = restored
        self.timedOut = timedOut
    }

    nonisolated deinit {}

    /// Whether tab `id` is hidden while its page decides its close.
    public func contains(_ id: String) -> Bool { entries[id] != nil }

    /// Takes `tabs` of `pane` out of its strip now (`store`: their daemon's); a page already asking keeps its tab.
    public func hide(_ tabs: [Tab], in pane: Pane, store: DaemonStore) {
        var hid = false
        for tab in tabs where entries[tab.id] == nil && tab.asks?() != true {
            guard let hide = HiddenTabClose.hide([tab.surface], in: store, panes: []) else { continue }
            let id = tab.id
            // task-owner: this hide (cancelled when it lifts, restores or times out); event driven (Observation).
            let watch = tab.asks.map { asks in
                Task { @MainActor [weak self] in
                    for await asked in ObservationStream(asks) where asked { break }
                    guard !Task.isCancelled else { return }
                    self?.restore(id)
                }
            }
            let timer = DemandTimer(owner: "tabs.hiddenPageClose")
            entries[id] = Entry(hide: hide, pane: pane, asks: tab.asks, watch: watch, timer: timer)
            timer.schedule(after: deadline) { @MainActor [weak self] in self?.expire(id) }
            hid = true
        }
        guard hid, let close = hidden(pane), paneCloses[ObjectIdentifier(pane)] == nil else { return }
        paneCloses[ObjectIdentifier(pane)] = close
    }

    /// The page closed tab `id` (no handler, or Leave): the hide ends, and the caller's close takes the
    /// tab out again in this turn. Its pane's hidden close yields to that close's own.
    @discardableResult
    public func lift(_ id: String) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.end()
        entry.hide.lift()
        if !entries.values.contains(where: { $0.pane === entry.pane }), let close = paneCloses.removeValue(forKey: ObjectIdentifier(entry.pane)) {
            lifted(entry.pane, close)
        }
        return true
    }

    /// The page of tab `id` closed it (no handler, or Leave): its decision is over. Returns the held pane, whose close
    /// takes the tab (a pane emptied by the hide is no longer shown, so nothing else finds it). `keepsHidden`: the tab
    /// stays out until that close prepares it (``lift(_:)`` from `prepareClose`), so a close of several tabs waiting
    /// for other pages shows no closed tab again meanwhile.
    public func pageClosed(_ id: String, keepsHidden: Bool) -> Pane? {
        guard let entry = entries[id] else { return nil }
        if keepsHidden { entry.end() } else { lift(id) }
        return entry.pane
    }

    /// The page of tab `id` neither closed nor asked in time: it closes without asking.
    public func expire(_ id: String) {
        guard let entry = entries[id] else { return }
        // A question that came just now, its watch not woken yet, is the person's: never answered Leave for them.
        if entry.asks?() == true { restore(id); return }
        guard lift(id) else { return }
        timedOut(entry.pane, id)
    }

    /// The page of tab `id` asks the person: the tab comes back at its
    /// place, selected, with its pane, before the question shows.
    @discardableResult
    public func restore(_ id: String) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.end()
        entry.hide.lift()
        restored(entry.pane, paneCloses.removeValue(forKey: ObjectIdentifier(entry.pane)), id) // its tab back: the pane is not empty
        return true
    }
}
