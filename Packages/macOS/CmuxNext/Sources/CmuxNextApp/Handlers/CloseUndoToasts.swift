import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import Observation

/// REOPEN-CLOSED (R102/R103): tabs the user closes (Cmd-W, a tab's close
/// button, the strip's context menu, close others / to the right / to the
/// left, closing a tab group) do not ask; an undo toast in their window
/// offers them back, and Cmd-Z runs that toast (TOAST-UNDO-KEY). A close is
/// announced before it happens (`expect`, `expectGroup`); the toast shows
/// once the daemon's closed history records every tab of that gesture (its
/// closed items of that pane), and its
/// action reopens exactly those records at their own places, never "the
/// newest". Only a costly close shows it (`CloseToastRule`: several real
/// tabs, an agent at work or an unsent chat, a terminal running a program);
/// Settings, New Tab, History and one idle tab close silently, and Cmd-Shift-T
/// still reopens them. "Closed “title”" for one tab, "Closed N tabs" for
/// several; closes made while a close toast shows join it, so one Undo
/// reopens them all. Automation closes (CLI, agents) never announce, so they
/// show no toast.
@MainActor
final class CloseUndoToasts {
    /// One announced gesture, waiting for its history records.
    struct Expected {
        /// Each tab's id, with the position it held before the gesture.
        var tabs: [(id: String, index: Int)]
        /// The daemon's closed items for them come from this pane.
        var paneResourceID: ResourceID?
        var title: String
        weak var window: NSWindow?
        var daemonItems: [String] = []
        var daemonTabs = 0
        /// `CloseToastRule`'s answer; nil while the daemon says whether a
        /// closing terminal runs a program.
        var costly: Bool?
        /// Matches the async program check to this gesture.
        var serial = 0
        /// Every history record arrived; the toast waits only for `costly`.
        var recorded = false
    }

    /// The close toast showing in a window, which a quick next close joins.
    private struct Shown {
        weak var handle: CmuxToastHandle?
        weak var window: NSWindow?
        var tabs: Int
        var reopen: @MainActor () -> Void
    }
    private var shown: Shown?
    private var nextSerial = 0

    private weak var services: AppServices?
    /// The presenter (tests replace it with a headless one).
    var toasts: CmuxToastCenter = .shared
    private var expected: [Expected] = []
    private var seenDaemonItems: Set<String> = []
    /// For `debug.filepages` (nxdog47): user closes announced, announcements
    /// that found no tab, and the newest closed items with whether a waiting
    /// gesture took them.
    private(set) var announced = 0
    private(set) var announcedEmpty = 0
    private(set) var recentDaemonItems: [(id: String, pane: String?, tabs: Int, matched: Bool)] = []
    /// The last reopen (`DaemonClosedHistory.reopen`): time to the daemon's
    /// reply and to the store holding the reopened objects (`debug.filepages`).
    private(set) var lastReopen: ReopenTiming?
    /// Watches the last reopen's tabs arrive in the store; the next reopen cancels it.
    var reopenWatch: Task<Void, Never>?

    struct ReopenTiming {
        var id: String
        var tabs: [String]
        var reply: Duration
        var applied: Duration?
        var tabsInStoreAtApplied: Bool?
        var tabsArrived: Duration?
    }

    func noteReopen(id: String, tabs: [String], reply: Duration) {
        lastReopen = ReopenTiming(id: id, tabs: tabs, reply: reply)
    }

    func noteReopenApplied(_ applied: Duration, tabsInStore: Bool) {
        lastReopen?.applied = applied
        lastReopen?.tabsInStoreAtApplied = tabsInStore
    }

    func noteReopenTabsArrived(_ arrived: Duration) {
        lastReopen?.tabsArrived = arrived
    }
    private var observation: Task<Void, Never>?
    static let toastID = "tab-closed"

    init(services: AppServices) {
        self.services = services
        let machines = services.machines
        seenDaemonItems = Set(Self.daemonItemIDs(machines.daemons))
        // task-owner: the service (cancelled in deinit); event-driven (Observation)
        observation = Task { [weak self] in
            for await ids in ObservationStream({ Self.daemonItemIDs(machines.daemons) }) {
                self?.daemonItemsChanged(ids)
            }
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            observation?.cancel()
            reopenWatch?.cancel()
        }
    }

    private static func daemonItemIDs(_ daemons: [DaemonService]) -> [String] {
        daemons.filter(\.store.servesStateResources).flatMap { $0.store.closedItems.map(\.id) }
    }

    /// A user's close of `ids` in `pane` (its close button, close others or
    /// to the right): announced, then closed, so its undo toast shows.
    /// An action run from automation (CLI, agents) closes without a toast.
    /// A terminal doing work asks once first (`TabCloseGuard`).
    static func close(in pane: PaneController, _ ids: [StripTabID]) {
        let user = isUserClose
        TabCloseGuard.close(ids.compactMap(pane.tab), on: pane.daemon, services: pane.services, window: pane.view.window) { [weak pane] in
            guard let pane else { return }
            guard user, let undo = pane.services.closedTabs?.undoToasts else { return pane.close(ids) }
            // Whether a closing terminal runs a program is read before the
            // close: a closed terminal ends, and could no longer say.
            guard case .askTerminals(let terminals) = CloseToastRule(services: pane.services).decide(ids.compactMap(pane.tab)) else {
                undo.expectGroup(ids, in: pane)
                return pane.close(ids)
            }
            // task-owner: one bounded process-info read per terminal (1 s each, concurrent), then the close
            Task { @MainActor [weak pane] in
                guard let daemon = pane?.daemon else { return }
                let programs = await DestructiveConfirmation.runningPrograms(of: terminals, on: daemon)
                guard let pane else { return }
                undo.expectGroup(ids, in: pane, costly: !programs.isEmpty)
                pane.close(ids)
            }
        }
    }

    /// No action run (a click in the strip) or a user-origin run.
    static var isUserClose: Bool { (ActionRunScope.current?.origin ?? .user) == .user }

    /// The user is closing tab `id` of `pane`.
    func expect(_ id: StripTabID, in pane: PaneController) {
        expectGroup([id], in: pane)
    }

    /// The user is closing tabs `ids` of `pane` in one gesture.
    func expectGroup(_ ids: [StripTabID], in pane: PaneController, costly: Bool? = nil) {
        expectGroup(tabs: ids.compactMap(pane.tab), in: pane.pane, daemon: pane.daemon, window: pane.view.window, costly: costly)
    }

    /// The user is closing `tabs` of `pane` in one gesture (a tab group
    /// that may not be shown; `window` is where the toast goes).
    /// `costly` is the caller's answer to `CloseToastRule` when it already
    /// read the closing terminals; nil asks the rule here.
    func expectGroup(tabs: [TabModel], in pane: PaneModel, daemon: DaemonService, window: NSWindow?, costly: Bool? = nil) {
        let entries = tabs.compactMap { tab in
            pane.tabs.firstIndex { $0 === tab }.map { (id: tab.id, index: $0) }
        }
        announced += 1
        guard !entries.isEmpty else { announcedEmpty += 1; return }
        let title = tabs.count == 1 ? Self.title(of: tabs[0], titles: services.map { TabTitleResolver(services: $0) } ?? TabTitleResolver()) : ""
        nextSerial += 1
        var close = Expected(tabs: entries.sorted { $0.index < $1.index }, paneResourceID: pane.resourceID,
                             title: title, window: window, serial: nextSerial)
        let decision: CloseToastRule.Decision = costly.map { $0 ? .show : .skip }
            ?? services.map { CloseToastRule(services: $0).decide(tabs) } ?? .skip
        switch decision {
        case .show: close.costly = true
        case .skip: close.costly = false
        case .askTerminals(let terminals):
            let serial = close.serial
            // task-owner: one bounded process-info read per terminal (1 s each, concurrent)
            Task { @MainActor [weak self] in
                let programs = await DestructiveConfirmation.runningPrograms(of: terminals, on: daemon)
                self?.decided(serial, costly: !programs.isEmpty)
            }
        }
        expected.append(close)
        if expected.count > 16 { expected.removeFirst(expected.count - 16) }
    }

    /// The program check of gesture `serial` answered.
    private func decided(_ serial: Int, costly: Bool) {
        guard let position = expected.firstIndex(where: { $0.serial == serial }) else { return }
        expected[position].costly = costly
        finishIfReady(position)
    }

    /// A tab's name in its toast, as its strip and the sidebar name it
    /// (`TabTitleResolver`): an agent chat by its chat, a page tab (a diff,
    /// Settings) by its page (cx-u1yn), a New Tab page or blank browser tab
    /// "New Tab", never the `about:blank` address their records carry.
    static func title(of tab: TabModel, titles: TabTitleResolver) -> String {
        titles.title(tab)
    }

    static func title(of tab: TabModel, pages: InternalPageTabStore) -> String {
        title(of: tab, titles: TabTitleResolver(pages: pages))
    }

    static func title(of tab: TabModel) -> String {
        title(of: tab, titles: TabTitleResolver())
    }

    private func daemonItemsChanged(_ ids: [String]) {
        let added = ids.filter { !seenDaemonItems.contains($0) }
        seenDaemonItems = Set(ids)
        guard let services else { return }
        for id in added {
            let entry = DaemonClosedHistory.entry(id, in: services)
            let position = entry.flatMap { entry in
                entry.item.kind == .tab ? expected.firstIndex { $0.paneResourceID != nil && $0.paneResourceID == entry.item.paneID } : nil
            }
            recentDaemonItems.append((id, entry?.item.paneID?.rawValue, entry?.item.tabs.count ?? 0, position != nil))
            if recentDaemonItems.count > 8 { recentDaemonItems.removeFirst(recentDaemonItems.count - 8) }
            guard let entry, let position else { continue }
            expected[position].daemonItems.append(id)
            expected[position].daemonTabs += max(entry.item.tabs.count, 1)
            guard expected[position].daemonTabs >= expected[position].tabs.count else { continue }
            expected[position].recorded = true
            finishIfReady(position)
        }
    }

    /// Shows (or drops) gesture `position` once its records are in and the
    /// rule has answered.
    private func finishIfReady(_ position: Int) {
        guard expected[position].recorded, let costly = expected[position].costly else { return }
        let close = expected.remove(at: position)
        guard costly else { return }
        show(close) { [weak services] in
            guard let services else { return }
            // Each item holds the position it had when it closed: reopen the last closed first.
            for id in close.daemonItems.reversed() {
                guard let entry = DaemonClosedHistory.entry(id, in: services) else { continue }
                DaemonClosedHistory.reopen(entry, services: services)
            }
        }
    }

    private func show(_ close: Expected, reopen: @escaping @MainActor () -> Void) {
        guard let window = close.window ?? services?.windows.active?.window else { return }
        var tabs = close.tabs.count, action = reopen
        // A close made while this window's close toast shows joins it: one toast, one Undo for all.
        if let previous = shown, let handle = previous.handle, !handle.isDismissed, previous.window === window {
            tabs += previous.tabs
            let earlier = previous.reopen
            action = { reopen(); earlier() }
        }
        let message = tabs > 1 ? MiscHandlerStrings.tabsClosed(tabs)
            : MiscHandlerStrings.tabClosed(close.title.isEmpty ? MiscHandlerStrings.untitledTab : close.title)
        let handle = toasts.show(CmuxToast(id: Self.toastID, message: message, action: .undo()), in: window)
        handle.onAction = action
        shown = Shown(handle: handle, window: window, tabs: tabs, reopen: action)
    }

    /// The gestures still waiting for their history records (`debug.filepages`).
    var waiting: [(pane: String?, tabs: Int, daemonTabs: Int)] {
        expected.map { ($0.paneResourceID?.rawValue, $0.tabs.count, $0.daemonTabs) }
    }
}
