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
/// again (``lift(_:)``, no flash). A page that asks (beforeunload's "Leave site?", or any question it
/// raises meanwhile) brings its tab back in place, selected, before the question (``restore(_:)``); so
/// does a page that has neither closed nor asked by ``deadline``, so no tab stays hidden with its page
/// running. `Pane` is the pane controller (compared by identity).
@MainActor
public final class HiddenPageCloses<Pane: AnyObject> {
    /// One hidden tab: its surface, and whether its page asks the person now (nil: no page to watch).
    public typealias Tab = (id: String, surface: SurfaceID, asks: (@MainActor @Sendable () -> Bool)?)

    private struct Entry {
        let hide: HiddenTabClose
        weak var pane: Pane?
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

    /// How long a hidden tab waits for its page to close or ask before it comes back.
    public var deadline: Duration = .seconds(5)

    /// - Parameter hidden: Shows a pane's tabs left; returns the pane's close when no tab is left.
    /// - Parameter lifted: A pane's close yields to the close its last hidden tab's page started.
    /// - Parameter restored: A tab comes back: the pane's close (if any) is taken back, the tab selected.
    public init(hidden: @escaping @MainActor (Pane) -> PendingPaneClose?, lifted: @escaping @MainActor (Pane, PendingPaneClose) -> Void,
                restored: @escaping @MainActor (Pane, PendingPaneClose?, String) -> Void) {
        self.hidden = hidden
        self.lifted = lifted
        self.restored = restored
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
            entries[id] = Entry(hide: hide, pane: pane, watch: watch, timer: timer)
            timer.schedule(after: deadline) { @MainActor [weak self] in self?.restore(id) }
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
        if let pane = entry.pane, !entries.values.contains(where: { $0.pane === pane }),
           let close = paneCloses.removeValue(forKey: ObjectIdentifier(pane)) {
            lifted(pane, close)
        }
        return true
    }

    /// The page of tab `id` asks the person (or did not decide in time): the tab comes back at its
    /// place, selected, with its pane, before the question shows.
    @discardableResult
    public func restore(_ id: String) -> Bool {
        guard let entry = entries.removeValue(forKey: id) else { return false }
        entry.end()
        entry.hide.lift()
        if let pane = entry.pane { restored(pane, paneCloses.removeValue(forKey: ObjectIdentifier(pane)), id) }
        return true
    }
}
