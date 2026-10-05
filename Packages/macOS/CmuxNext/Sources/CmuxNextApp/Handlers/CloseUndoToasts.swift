import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import Observation

/// REOPEN-CLOSED (R102/R103): tabs the user closes (Cmd-W, a tab's close
/// button, the strip's context menu, close others / to the right / to the
/// left, closing a tab group) do not ask; an undo toast in their window
/// offers them back, and Cmd-Z runs that toast (TOAST-UNDO-KEY). A close is
/// announced before it happens (`expect`, `expectGroup`); the toast shows
/// once the closed history records every tab of that gesture (the app's
/// tracker, or the daemon's closed-history items of that pane), and its
/// action reopens exactly those records at their own places, never "the
/// newest". One gesture, one toast: "Closed “title”" for one tab, "Closed
/// N tabs" for a group. One close toast per window: a newer close replaces
/// it. Automation closes (CLI, agents) never announce, so they show no toast.
@MainActor
final class CloseUndoToasts {
    /// One announced gesture, waiting for its history records.
    struct Expected {
        /// The tracker's record id (`<machine>/<tab id>`) of each tab, with
        /// the position it held before the gesture.
        var tabs: [(trackerTabID: String, index: Int)]
        /// The daemon's closed items for them come from this pane.
        var paneResourceID: ResourceID?
        var title: String
        weak var window: NSWindow?
        var records: [ClosedTabHistory.Record] = []
        var daemonItems: [String] = []
        var daemonTabs = 0
    }

    private weak var services: AppServices?
    /// The presenter (tests replace it with a headless one).
    var toasts: CmuxToastCenter = .shared
    private var expected: [Expected] = []
    private var seenDaemonItems: Set<String> = []
    private var observation: Task<Void, Never>?
    static let toastID = "tab-closed"

    init(services: AppServices) {
        self.services = services
        let machines = services.machines
        seenDaemonItems = Set(Self.daemonItemIDs(machines.daemons))
        // task-owner: the service (cancelled in deinit); event-driven (Observation)
        observation = Task { [weak self] in
            for await ids in Observations({ Self.daemonItemIDs(machines.daemons) }) {
                self?.daemonItemsChanged(ids)
            }
        }
    }

    isolated deinit { observation?.cancel() }

    private static func daemonItemIDs(_ daemons: [DaemonService]) -> [String] {
        daemons.filter(\.store.servesStateResources).flatMap { $0.store.closedItems.map(\.id) }
    }

    /// A user's close of `ids` in `pane` (its close button, close others or
    /// to the right): announced, then closed, so its undo toast shows.
    /// An action run from automation (CLI, agents) closes without a toast.
    static func close(in pane: PaneController, _ ids: [StripTabID]) {
        if isUserClose { pane.services.closedTabs?.undoToasts.expectGroup(ids, in: pane) }
        pane.close(ids)
    }

    /// No action run (a click in the strip) or a user-origin run.
    static var isUserClose: Bool { (ActionRunScope.current?.origin ?? .user) == .user }

    /// The user is closing tab `id` of `pane`.
    func expect(_ id: StripTabID, in pane: PaneController) {
        expectGroup([id], in: pane)
    }

    /// The user is closing tabs `ids` of `pane` in one gesture.
    func expectGroup(_ ids: [StripTabID], in pane: PaneController) {
        expectGroup(tabs: ids.compactMap(pane.tab), in: pane.pane, daemon: pane.daemon, window: pane.view.window)
    }

    /// The user is closing `tabs` of `pane` in one gesture (a tab group
    /// that may not be shown; `window` is where the toast goes).
    func expectGroup(tabs: [TabModel], in pane: PaneModel, daemon: DaemonService, window: NSWindow?) {
        let entries = tabs.compactMap { tab in
            pane.tabs.firstIndex { $0 === tab }.map { (trackerTabID: ClosedTabTracker.qualified(daemon.machineID, tab.id), index: $0) }
        }
        guard !entries.isEmpty else { return }
        expected.append(Expected(tabs: entries.sorted { $0.index < $1.index }, paneResourceID: pane.resourceID,
                                 title: tabs.count == 1 ? tabs[0].displayTitle : "", window: window))
        if expected.count > 16 { expected.removeFirst(expected.count - 16) }
    }

    /// The app's tracker recorded a closed tab.
    func trackerRecorded(_ record: ClosedTabHistory.Record) {
        guard let position = expected.firstIndex(where: { $0.tabs.contains { $0.trackerTabID == record.tabID } }) else { return }
        expected[position].records.append(record)
        guard expected[position].records.count == expected[position].tabs.count else { return }
        let close = expected.remove(at: position)
        show(close) { [weak services] in
            guard let services, let tracker = services.closedTabs else { return }
            // Ascending original positions, so each tab lands where it was.
            for (tabID, index) in close.tabs {
                guard var record = tracker.take(tabID) else { continue }
                record.index = index
                tracker.reopen(record, fallback: services.windows.active?.focusedPane)
            }
        }
    }

    private func daemonItemsChanged(_ ids: [String]) {
        let added = ids.filter { !seenDaemonItems.contains($0) }
        seenDaemonItems = Set(ids)
        guard let services else { return }
        for id in added {
            guard let entry = DaemonClosedHistory.entry(id, in: services), entry.item.kind == .tab,
                  let position = expected.firstIndex(where: { $0.paneResourceID != nil && $0.paneResourceID == entry.item.paneID })
            else { continue }
            expected[position].daemonItems.append(id)
            expected[position].daemonTabs += max(entry.item.tabs.count, 1)
            guard expected[position].daemonTabs >= expected[position].tabs.count else { continue }
            let close = expected.remove(at: position)
            show(close) { [weak services] in
                guard let services else { return }
                // Each item holds the position it had when it closed: reopen the last closed first.
                for id in close.daemonItems.reversed() {
                    guard let entry = DaemonClosedHistory.entry(id, in: services) else { continue }
                    DaemonClosedHistory.reopen(entry, services: services)
                }
            }
        }
    }

    private func show(_ close: Expected, reopen: @escaping @MainActor () -> Void) {
        guard let window = close.window ?? services?.windows.active?.window else { return }
        let message = close.tabs.count > 1 ? MiscHandlerStrings.tabsClosed(close.tabs.count)
            : MiscHandlerStrings.tabClosed(close.title.isEmpty ? MiscHandlerStrings.untitledTab : close.title)
        let handle = toasts.show(CmuxToast(id: Self.toastID, message: message, action: .undo()), in: window)
        handle.onAction = reopen
    }
}
