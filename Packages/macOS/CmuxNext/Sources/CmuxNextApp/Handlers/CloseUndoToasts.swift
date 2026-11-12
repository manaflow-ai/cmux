import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs
import CmuxNextWindowRules
import Observation

/// REOPEN-CLOSED (R102/R103): tabs the user closes (Cmd-W, a tab's close
/// button, the strip's context menu, close others / to the right / to the
/// left, closing a tab group) do not ask; an undo toast in their window
/// offers them back, and Cmd-Z runs that toast (TOAST-UNDO-KEY). A close is
/// announced before it happens (`expectGroup`); the toast shows
/// once the daemon's closed history records every tab of that gesture (its
/// closed items of that pane), and its
/// action reopens exactly those records at their own places, never "the
/// newest". Only a costly close shows it (`CloseToastRule`: several real
/// tabs, an agent at work or an unsent chat); Settings, New Tab, History and
/// one tab that is not working (a terminal too) close silently, and Cmd-Shift-T
/// still reopens them. "Closed “title”" for one tab, "Closed N tabs" for
/// several; closes made while a close toast shows join it, so one Undo
/// reopens them all. Automation closes (CLI, agents) never announce, so they
/// show no toast.
@MainActor
final class CloseUndoToasts {
    /// One announced gesture's toast: its title (one tab's) and window. Which records it waits for
    /// is the reducer's (cmux-window-rules `closed::expect` / `record`), keyed by its token.
    private struct Gesture {
        var title: String
        weak var window: NSWindow?
    }

    /// The close toast showing in a window, which a quick next close joins.
    private struct Shown {
        weak var handle: CmuxToastHandle?
        weak var window: NSWindow?
        var tabs: Int
        var reopen: @MainActor () -> Void
    }
    private var shown: Shown?

    private weak var services: AppServices?
    /// The presenter (tests replace it with a headless one).
    var toasts: CmuxToastCenter = .shared
    /// At most one new close toast per id in its gap (tab and workspace closes); joins are not counted.
    var rateLimit = UndoToastRateLimit()
    /// The time the rate limit reads (tests pass their own).
    var now: @MainActor () -> ContinuousClock.Instant = { .now }
    /// Whether a person's close of a tab waits for its page: a live Chromium
    /// page runs its beforeunload first (`BrowserUserClosing`) and closes the
    /// tab itself afterwards. Starts that page's close. Tests pass their own.
    var pageDecidesClose: @MainActor (PaneController, StripTabID) -> Bool = CloseUndoToasts.livePageDecidesClose
    /// Tabs whose page decides a person's close now: a quick next Cmd-W skips them (``PageClosingTabs``).
    let pageClosing = PageClosingTabs()
    /// Those tabs, out of their strip (and an emptied pane out of its window) while the page decides; a page that asks brings its tab back.
    let hiddenPages = HiddenPageCloses<PaneController>(
        hidden: { pane in pane.apply(pane.snapshot()); return pane.stripModel.tabs.isEmpty ? pane.showPaneClose() : nil },
        lifted: { pane, close in pane.workspace?.layoutModel.cancelPaneClose(close) },
        restored: { held, _, id in if let workspace = held.workspace, workspace.layoutModel.withdrawPaneClose(held.layoutPaneID) { workspace.applyCurrent() }; let pane = held.services.paneController(for: held.pane) ?? held; pane.apply(pane.snapshot()); pane.select(StripTabID(id)) }, // whichever close hid the pane
        timedOut: { pane, id in pane.services.closedTabs?.undoToasts.pageClosing.end(id); pane.close([StripTabID(id)]) }) // the daemon's close: never asks
    /// Closes of several tabs waiting for their pages, so each stays one Reopen Closed step.
    let pageDecidedCloses = PageDecidedCloses<PaneController, PreparedTabClose>(
        prepare: { pane, ids in pane.prepareClose(ids) }, send: { PaneController.send($0, from: $1, userClose: $2) })

    /// ``pageDecidesClose``'s answer in the app: the tab's browser page decides.
    static func livePageDecidesClose(_ pane: PaneController, _ id: StripTabID) -> Bool {
        pane.services.cache.browsers[id.rawValue]?.tab.pageDecidesUserClose() == true
    }

    /// Whether a new close toast `id` may show now (`rateLimit`).
    func allowsNewToast(_ id: String) -> Bool {
        rateLimit.allows(id, at: now())
    }
    /// The gestures waiting for their history records (the reducer's state) and their toasts.
    private var undo = WindowRules.UndoState()
    private var gestures: [UInt64: Gesture] = [:]
    private var nextToken: UInt64 = 0
    private var seenDaemonItems: Set<String> = []
    /// For `debug.filepages` (nxdog47): user closes announced, announcements
    /// that found no tab, and the newest closed items with whether a waiting
    /// gesture took them.
    private(set) var announced = 0
    private(set) var announcedEmpty = 0
    private(set) var recentDaemonItems: [(id: String, pane: String?, tabs: Int, matched: Bool)] = []
    /// The last reopen (`DaemonClosedHistory.reopen`): time to the daemon's
    /// reply and to the store holding the reopened objects (`debug.filepages`).
    var lastReopen: ReopenTiming?
    /// Watches the last reopen's tabs arrive in the store; the next reopen cancels it.
    var reopenWatch: Task<Void, Never>?
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
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        observation?.cancel()
        reopenWatch?.cancel()
    }

    private static func daemonItemIDs(_ daemons: [DaemonService]) -> [String] {
        daemons.filter(\.store.servesStateResources).flatMap { $0.store.closedItems.map(\.id) }
    }

    /// A user's close of `ids` in `pane` (its close button, close others or
    /// to the right): announced, then closed, so its undo toast shows.
    /// An action run from automation (CLI, agents) closes without a toast.
    /// A terminal doing work asks once first (`TabCloseGuard`). `selecting` (`TabStripModel.selectionKeeping`) stays and is selected as the close runs.
    static func close(in pane: PaneController, _ ids: [StripTabID], selecting: StripTabID? = nil) { close([(pane: pane, ids: ids)], selecting: selecting.map { (pane: pane, id: $0) }) }

    /// One gesture over tabs of several panes (a pane's close others): one
    /// question and one toast decision over every closing tab (cx-lb4al).
    static func close(_ parts: [(pane: PaneController, ids: [StripTabID])], selecting: (pane: PaneController, id: StripTabID)? = nil) {
        // A tab still being created is cancelled now and leaves the gesture: no question, read or daemon close for it (CancelledCreation).
        let pending = Set(parts.flatMap { part in part.ids.filter { part.pane.daemon.store.creations.isPending(tab: $0.rawValue) } })
        let resolved: [(pane: PaneController, ids: [StripTabID])] = parts.map { part in part.pane.close(part.ids.filter(pending.contains)); return (part.pane, part.ids.map { part.pane.tab($0).map { StripTabID($0.id) } ?? $0 }) } // a stand-in the store replaced: its tab's id, so that tab's page decides its close (#31837)
        // A tab already closing left the store's visible records with its close intent, so a
        // second close of it (before the daemon answered the first) finds nothing to close.
        // A page's own close of its tab, after a close of several tabs waited for it, joins that close.
        let undoToasts = parts.first?.pane.services.closedTabs?.undoToasts
        // A close of a tab whose page was deciding (the page's own close after it decided, a close
        // button): that decision is over; the close below starts a new one if the page decides again.
        for part in resolved { for id in part.ids { undoToasts?.pageClosing.end(id.rawValue) } }
        let parts = (undoToasts?.pageDecidedCloses.absorb(resolved) ?? resolved).map { part in (pane: part.pane, ids: part.ids.filter { !pending.contains($0) }) }.filter { !$0.ids.isEmpty }
        guard let first = parts.first?.pane else { return }
        let user = isUserClose, services = first.services, daemon = first.daemon
        // The kind is chosen once, over every pane of the workspace: its last tabs close the workspace, at once, through
        // Close Workspace's one path (`WorkspaceCloseFlow`, as the row's close button runs it), so nothing in it moves.
        if let workspace = first.workspace?.workspace, parts.allSatisfy({ $0.pane.workspace?.workspace === workspace }), TabCloseKind(panes: workspace.screens.flatMap(\.panes).map { model in
            let closing = parts.filter { $0.pane.pane === model }.flatMap(\.ids)
            return (!closing.isEmpty, services.paneController(for: model).map { TabCloseGuard.empties($0, closing: closing) } ?? model.tabs.isEmpty)
        }, home: workspace.isAnyHome) == .workspace {
            var run = user ? ActionInvocation(closingRow: workspace.id) : ActionInvocation(target: .init(kind: .workspace, id: workspace.id), origin: ActionRunScope.current?.origin ?? .cli).confirmed()
            run.closesRowOnly = true
            _ = services.registry.perform("closeWorkspace", invocation: run.onMachine(daemon.machineID)); return
        }
        let tabs = parts.flatMap { part in part.ids.compactMap(part.pane.tab) }
        let panes = parts.map { part in (pane: { @MainActor [weak pane = part.pane] in pane }, ids: part.ids) }
        // One gesture, one daemon close and one closed group (`PaneController.close(_:)`): one Reopen
        // Closed brings every pane's tabs back, and one undo toast counts them all.
        let closeAll = { @MainActor [weak kept = selecting?.pane, keptID = selecting?.id] (undo: CloseUndoToasts?, costly: Bool) in
            if let kept, let keptID, kept.stripModel.tab(keptID) != nil { kept.select(keptID) } // after any question; a hide selected it already (TabCloseGuard)
            var closing: [(pane: PaneController, ids: [StripTabID])] = [], deciding: [(pane: PaneController, ids: [StripTabID])] = []
            for part in panes {
                guard let pane = part.pane() else { continue }
                // A person's close of a live page runs its beforeunload first (`BrowserUserClosing`): the page
                // decides, and its own close (after Leave) closes the tab then.
                let decides = pane.services.closedTabs?.undoToasts.pageDecidesClose ?? CloseUndoToasts.livePageDecidesClose
                let deciders = user ? part.ids.filter { !pane.isMirror($0) && decides(pane, $0) } : [] // a mirror's close takes out the chip, never the page
                if let undo = pane.services.closedTabs?.undoToasts {
                    for id in deciders { if let page = pane.services.cache.browsers[id.rawValue]?.tab { undo.pageClosing.begin(id.rawValue, page: page) } }
                }
                closing.append((pane, part.ids.filter { !deciders.contains($0) }))
                if !deciders.isEmpty { deciding.append((pane, deciders)) }
            }
            let all = closing.map(\.ids.count).reduce(0, +) + deciding.map(\.ids.count).reduce(0, +)
            let daemon = (closing.first ?? deciding.first)?.pane.daemon
            // One close of several tabs is one Reopen Closed step even when pages decide (Lawrence
            // 2026-10-23, Cmd-Opt-T then Cmd-Shift-T): it waits for them (`PageDecidedCloses`).
            if let undo, !deciding.isEmpty, all > 1, (closing + deciding).allSatisfy({ $0.pane.daemon === daemon }) {
                let parts = closing.map { part in (pane: part.pane, ids: part.ids + (deciding.first { $0.pane === part.pane }?.ids ?? [])) }
                    + deciding.filter { part in !closing.contains { $0.pane === part.pane } }
                undo.expectGroup(parts, costly: costly)
                undo.pageDecidedCloses.begin(closing: closing.filter { !$0.ids.isEmpty }, deciding: deciding, userClose: user)
                for part in deciding { undo.hidePages(part.ids, in: part.pane) }
                return
            }
            closing = closing.filter { !$0.ids.isEmpty }
            undo?.expectGroup(closing, costly: costly)
            PaneController.close(closing)
            for part in deciding { part.pane.services.closedTabs?.undoToasts.hidePages(part.ids, in: part.pane) } // they leave now too
        }
        TabCloseGuard.close(tabs, on: daemon, services: services, window: first.view.window, leaving: parts, keeping: selecting) { [weak services] _, hidden in
            hidden?.lift()
            guard user, let undo = services?.closedTabs?.undoToasts else { return closeAll(nil, false) }
            closeAll(undo, undo.isCostly(tabs))
        }
    }

    /// Tabs `ids` of `pane` whose page decides their close leave now, their pages alive (`hiddenPages`).
    func hidePages(_ ids: [StripTabID], in pane: PaneController) {
        let tabs = ids.compactMap { id in pane.tab(id).map { (id: id.rawValue, surface: $0.surface, asks: pane.services.cache.browsers[id.rawValue].map { PageClosingTabs.asksPerson($0.tab) }) } }
        hiddenPages.hide(tabs, in: pane, store: pane.daemon.store)
    }

    /// `CloseToastRule`'s answer for `tabs`, read before their close runs: whether the close earns its undo toast.
    /// Synchronous: no terminal is asked what it runs (Lawrence 2026-11-09, one idle terminal's toast).
    func isCostly(_ tabs: [TabModel]) -> Bool {
        switch services.map({ CloseToastRule(services: $0).decide(tabs) }) ?? .skip {
        case .show: true
        case .skip: false
        }
    }

    /// No action run (a click in the strip) or a user-origin run.
    static var isUserClose: Bool { (ActionRunScope.current?.origin ?? .user) == .user }

    /// The user is closing tabs `ids` of `pane` in one gesture; `costly` is `isCostly`'s answer.
    func expectGroup(_ ids: [StripTabID], in pane: PaneController, costly: Bool) {
        expectGroup(tabs: ids.compactMap(pane.tab), in: pane.pane, window: pane.view.window, costly: costly)
    }

    /// The user is closing tabs of several panes in one gesture: one daemon
    /// close of one daemon (`PaneController.close(_:)`) stores one closed
    /// group for all of them, so the gesture waits for one item from any of
    /// those panes. Parts on several daemons each wait for their own.
    func expectGroup(_ parts: [(pane: PaneController, ids: [StripTabID])], costly: Bool) {
        guard let daemon = parts.first?.pane.daemon, parts.count > 1, parts.allSatisfy({ $0.pane.daemon === daemon }) else {
            for part in parts { expectGroup(part.ids, in: part.pane, costly: costly) }
            return
        }
        expectGroup(parts.map { part in (tabs: part.ids.compactMap(part.pane.tab), pane: part.pane.pane) },
                    window: parts.first?.pane.view.window, costly: costly)
    }

    /// The user is closing `tabs` of `pane` in one gesture (a tab group
    /// that may not be shown; `window` is where the toast goes).
    func expectGroup(tabs: [TabModel], in pane: PaneModel, window: NSWindow?, costly: Bool) {
        expectGroup([(tabs: tabs, pane: pane)], window: window, costly: costly)
    }

    private func expectGroup(_ parts: [(tabs: [TabModel], pane: PaneModel)], window: NSWindow?, costly: Bool) {
        let entries = parts.flatMap { part in
            part.tabs.compactMap { tab in part.pane.tabs.firstIndex { $0 === tab }.map { (id: tab.id, index: $0) } }
        }
        let tabs = parts.flatMap(\.tabs)
        announced += 1
        nextToken += 1
        let token = nextToken
        guard let (state, outcome) = WindowRules().expectClose(undo, token: token, tabs: entries,
                                                              panes: parts.compactMap(\.pane.resourceID?.rawValue), costly: costly) else { return }
        undo = state
        switch outcome {
        case .empty: announcedEmpty += 1
        case .repeated: break
        case .waiting(let dropped):
            let title = tabs.count == 1 ? Self.title(of: tabs[0], titles: services.map { TabTitleResolver(services: $0) } ?? TabTitleResolver()) : ""
            gestures[token] = Gesture(title: title, window: window)
            for old in dropped { gestures[old] = nil }
        }
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
        guard let services, !added.isEmpty else { return }
        let entries = added.map { DaemonClosedHistory.entry($0, in: services) }
        let items = zip(added, entries).map { id, entry in
            WindowRules.RecordedItem(id: id, kind: entry?.item.kind, pane: entry?.item.paneID?.rawValue, tabs: entry?.item.tabs.count ?? 0)
        }
        guard let (state, matched, settled) = WindowRules().recordClosed(undo, items: items) else { return }
        undo = state
        for (index, id) in added.enumerated() {
            let entry = entries[index]
            recentDaemonItems.append((id, entry?.item.paneID?.rawValue, entry?.item.tabs.count ?? 0, matched.indices.contains(index) && matched[index]))
        }
        if recentDaemonItems.count > 8 { recentDaemonItems.removeFirst(recentDaemonItems.count - 8) }
        // Every record of a gesture is in: show its toast (a costly close) or drop it.
        for close in settled {
            guard let gesture = gestures.removeValue(forKey: close.token), close.shows else { continue }
            show(tabs: close.tabs, title: gesture.title, window: gesture.window) { [weak services] in
                guard let services else { return }
                // Each item holds the position it had when it closed: reopen the last closed first.
                for id in close.items.reversed() {
                    guard let entry = DaemonClosedHistory.entry(id, in: services) else { continue }
                    DaemonClosedHistory.reopen(entry, services: services)
                }
            }
        }
    }

    private func show(tabs closed: Int, title: String, window: NSWindow?, reopen: @escaping @MainActor () -> Void) {
        guard let window = window ?? services?.windows.active?.window else { return }
        // A close made while this window's close toast shows joins it: one toast, one Undo for all.
        let previous = shown.flatMap { shown in shown.handle.map { !$0.isDismissed && shown.window === window } == true ? shown : nil }
        let tabs: Int, action: @MainActor () -> Void
        switch WindowRules().undoToast(tabs: closed, shown: previous?.tabs, allowed: previous != nil || allowsNewToast(Self.toastID)) {
        case .drop:
            // Too soon after the last close toast: Reopen Closed and History still bring it back.
            return
        case .join(let total):
            let earlier = previous?.reopen
            tabs = total
            action = { reopen(); earlier?() }
        case .new(let total):
            tabs = total
            action = reopen
        }
        let message = tabs > 1 ? MiscHandlerStrings.tabsClosed(tabs)
            : MiscHandlerStrings.tabClosed(title.isEmpty ? MiscHandlerStrings.untitledTab : title)
        let handle = toasts.show(CmuxToast(id: Self.toastID, message: message, action: .undo()), in: window)
        handle.onAction = action
        shown = Shown(handle: handle, window: window, tabs: tabs, reopen: action)
    }

    /// The gestures still waiting for their history records (`debug.filepages`).
    var waiting: [(pane: String?, tabs: Int, daemonTabs: Int)] {
        undo.waiting.map { ($0.panes.sorted().joined(separator: ","), $0.tabs, $0.recorded) }
    }
}
