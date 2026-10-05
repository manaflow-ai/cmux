import AppKit
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import Observation

/// REOPEN-CLOSED (R102/R103): a tab the user closes (Cmd-W, its close
/// button, the strip's context menu) does not ask; an undo toast in its
/// window offers to reopen it, and Cmd-Z runs that toast (TOAST-UNDO-KEY).
/// The close is announced before it happens (`expect`); the toast shows when
/// the closed history records that exact tab (the app's tracker, or the
/// daemon's closed-history items), and its action reopens that record, not
/// the newest one. One close toast per window: a newer close replaces it.
/// Automation closes (CLI, agents) never announce, so they show no toast.
@MainActor
final class CloseUndoToasts {
    /// One announced close, waiting for its history record.
    struct Expected {
        /// The tracker's record id (`<machine>/<tab id>`).
        var trackerTabID: String
        /// The daemon's closed item for it: same pane, same position.
        var paneResourceID: ResourceID?
        var index: Int
        var title: String
        weak var window: NSWindow?
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
                self?.daemonItemsChanged(Set(ids))
            }
        }
    }

    isolated deinit { observation?.cancel() }

    private static func daemonItemIDs(_ daemons: [DaemonService]) -> [String] {
        daemons.filter(\.store.servesStateResources).flatMap { $0.store.closedItems.map(\.id) }
    }

    /// The user is closing tab `id` of `pane`: show the toast when the
    /// history records it.
    func expect(_ id: StripTabID, in pane: PaneController) {
        guard let tab = pane.tab(id), let index = pane.pane.tabs.firstIndex(where: { $0 === tab }) else { return }
        expected.append(Expected(trackerTabID: ClosedTabTracker.qualified(pane.daemon.machineID, tab.id), paneResourceID: pane.pane.resourceID,
                                 index: index, title: tab.displayTitle, window: pane.view.window))
        if expected.count > 16 { expected.removeFirst(expected.count - 16) }
    }

    /// The user is closing several tabs of `pane` in one gesture (close
    /// others, to the right or left, a tab group): one toast offers the whole
    /// group back.
    func expectGroup(_ ids: [StripTabID], in pane: PaneController) {}

    /// The app's tracker recorded a closed tab.
    func trackerRecorded(_ record: ClosedTabHistory.Record) {
        guard let position = expected.firstIndex(where: { $0.trackerTabID == record.tabID }) else { return }
        let close = expected.remove(at: position)
        show(close) { [weak services] in
            guard let services, let tracker = services.closedTabs, let record = tracker.take(record.tabID) else { return }
            tracker.reopen(record, fallback: services.windows.active?.focusedPane)
        }
    }

    private func daemonItemsChanged(_ ids: Set<String>) {
        let added = ids.subtracting(seenDaemonItems)
        seenDaemonItems = ids
        guard let services else { return }
        for id in added {
            guard let entry = DaemonClosedHistory.entry(id, in: services), entry.item.kind == .tab,
                  let position = expected.firstIndex(where: { $0.paneResourceID != nil && $0.paneResourceID == entry.item.paneID
                      && $0.index == entry.item.index }) else { continue }
            let close = expected.remove(at: position)
            show(close) { [weak services] in
                guard let services, let entry = DaemonClosedHistory.entry(id, in: services) else { return }
                DaemonClosedHistory.reopen(entry, services: services)
            }
        }
    }

    private func show(_ close: Expected, reopen: @escaping @MainActor () -> Void) {
        guard let window = close.window ?? services?.windows.active?.window else { return }
        let title = close.title.isEmpty ? MiscHandlerStrings.untitledTab : close.title
        let handle = toasts.show(CmuxToast(id: Self.toastID, message: MiscHandlerStrings.tabClosed(title), action: .undo()), in: window)
        handle.onAction = reopen
    }
}
