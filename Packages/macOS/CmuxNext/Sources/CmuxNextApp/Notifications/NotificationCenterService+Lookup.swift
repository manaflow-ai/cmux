import AppKit
import CmuxNextAgentPane
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextBridge
import CmuxNextSettings
import CmuxNextFocus

/// Tab lookups, the dock badge and the pane attention marks.
extension NotificationCenterService {
    /// The tab `resolved` types into: a terminal, a page (with its bars) or an agent chat.
    static func contentTab(_ resolved: FocusState.Resolved) -> String? {
        switch resolved {
        case .terminal(_, let tab), .browserPage(_, let tab), .addressBar(_, let tab), .findBar(_, let tab), .devTools(_, let tab),
             .agentPage(_, let tab), .page(_, let tab), .conversation(_, let tab): tab
        default: nil
        }
    }

    /// The workspace focus of `controller` that the person sees: nil while a top page (History,
    /// Settings, the App Store) covers the workspace, whose focus model still names the pane
    /// underneath. Every "viewed" and "typed into" rule reads this, never the raw focus model.
    static func shownFocus(_ c: WindowController) -> FocusState.Resolved? { c.shownTopPage == nil ? c.focus.state.resolved : nil }

    /// The content tab of the window whose focus owns `window` (a Chromium
    /// page window resolves to its cmux window).
    func focusedTab(in window: NSWindow?) -> String? {
        guard let services, let window = CmuxApplication.accessibilityWindow(for: window) else { return nil }
        let controller = services.windows.controllers.first { $0.window === window }
        return controller.flatMap(Self.shownFocus).flatMap(Self.contentTab)
    }

    /// `window`'s focus is a terminal (not a page, address bar, or find bar).
    func isTerminalFocused(in window: NSWindow?) -> Bool {
        guard let services, let window = CmuxApplication.accessibilityWindow(for: window),
              let controller = services.windows.controllers.first(where: { $0.window === window }),
              case .terminal? = Self.shownFocus(controller) else { return false }
        return true
    }

    /// The tab is the focused content of the key window while cmux is active.
    func isViewed(_ tabID: String) -> Bool {
        guard let services, services.appActiveSource() else { return false }
        return services.windows.controllers.contains { $0.focus.state.windowKey && Self.shownFocus($0).flatMap(Self.contentTab) == tabID }
    }

    static func tab(id: String, in store: DaemonStore) -> TabModel? { // perf-hot: 0.1ms key-dispatch (every key-down: noteTyping)
        // The store's index: every keystroke looks its tab up here (noteTyping), so no walk over every tab.
        store.tab(id: id)
    }

    func locate(surface: SurfaceID, in store: DaemonStore) -> LocatedTab? {
        guard let tab = store.tab(surface: surface), let pane = store.pane(containing: surface),
              let workspace = store.workspace(containing: pane.handle) else { return nil }
        return LocatedTab(tab: tab, pane: pane, workspace: workspace)
    }

    /// Each workspace adds its unread tab count, or 1 when that count is 0
    /// and the workspace is marked unread by hand: a mark adds nothing to a
    /// workspace that already has unread tabs (roughly the old app's count).
    /// Home's unread conversations (`homeUnread`, conversation ids) add one
    /// each, as Messages' Dock badge counts its unread; a conversation that a
    /// workspace tab shows with its own unread marker is already counted.
    /// The store keeps the counts per workspace (``DaemonStore/unreadTotals``): an observer of this
    /// count observes one value, never the tabs.
    static func unreadCount(_ store: DaemonStore?, homeUnread: [String] = []) -> Int {
        store?.unreadBadge(homeUnread: homeUnread) ?? Set(homeUnread).count
    }

    /// The badge count now: the store's unread tabs and Home's unread conversations.
    func currentUnreadCount() -> Int {
        let home = services?.home.unreadConversations ?? []
        return Self.unreadCount(services?.daemon.store, homeUnread: home.map(\.rawValue))
    }

    /// Sets the Dock tile's unread count (``DockBadge``: written only when it changes, and again
    /// when the Dock icon comes back).
    func updateDockBadge(_ count: Int) {
        dockAttention.unreadChanged(count)
        dockBadge.show(preferences.dockBadge && count > 0 ? String(count) : nil)
    }

    /// The handoff driver over the local daemon and this Mac's install
    /// principal (`feed.adopt` is an install-only owner op).
    func makeFeedDriver(_ services: AppServices, principal: FeedInstallPrincipal) -> FeedHandoffDriver {
        let feed = services.feed
        let daemon = services.daemon
        func connection() throws -> DaemonConnection {
            guard let connection = daemon.connection else { throw DaemonError.notConnected }
            return connection
        }
        return FeedHandoffDriver(
            daemon: .init(
                serves: { daemon.isLocal && daemon.identity?.supports(DaemonCapability.feedLocalOwner.rawValue) == true },
                list: { state, unread in
                    try await connection().request(FeedLocalListRequest(state: state, unread: unread ? true : nil)).items
                },
                begin: { try await connection().request(FeedLocalHandoffBeginRequest(item: $0)).item },
                done: { try await connection().request(FeedLocalHandoffDoneRequest(item: $0, home: $1)).item }),
            owner: { path, body in try await principal.call(path, body) },
            isSignedIn: { [weak feed] in feed?.isSignedIn ?? false },
            installID: { principal.installID },
            policy: { [weak self] in self?.feedHandoffPolicy() ?? FeedHandoffPolicy(preferences: .init(), mutedWorkspaces: []) },
            since: Self.handoffSince)
    }

    /// The first time the driver ran for `install` (ms), kept per Mac: open
    /// items from before it stay local, so nothing the removed step-1 bridge
    /// already posted is adopted a second time.
    static func handoffSince(_ install: String) -> UInt64 {
        let key = "feed.handoff.since.\(install)"
        if let stored = UserDefaults.standard.object(forKey: key) as? NSNumber { return stored.uint64Value }
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        UserDefaults.standard.set(NSNumber(value: now), forKey: key)
        return now
    }

    /// The handoff rules under the current settings. Muted workspaces are
    /// matched by durable key and by public id (`ws_…`, an item's context);
    /// incognito windows' workspaces (`WindowManager.isIncognito`) also by
    /// their terminals' public ids, so none of their items leaves the Mac.
    func feedHandoffPolicy() -> FeedHandoffPolicy {
        var muted = preferences.mutedWorkspaces, incognito = Set<String>()
        for workspace in services?.daemon.store.workspaces ?? [] {
            if muted.contains(workspace.id), let resource = workspace.resourceID { muted.insert(resource.rawValue) }
            guard services?.windows.isIncognito(workspace: workspace.id) == true else { continue }
            incognito.insert(workspace.id)
            if let resource = workspace.resourceID { incognito.insert(resource.rawValue) }
            for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) {
                if let terminal = tab.terminalResourceID { incognito.insert(terminal.rawValue) }
            }
        }
        return FeedHandoffPolicy(preferences: preferences, mutedWorkspaces: muted, incognito: incognito)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Attention marks for `workspace`'s panes: every pane whose shown tab
    /// reads unread (``TabModel/showsUnread``: an unread notification or Mark
    /// as Unread, the value every unread dot reads; ``unreadRing(of:dismissed:)``),
    /// unless the workspace is muted or the style is `none`. As
    /// classic's ring lived on the notifying terminal, a pane showing a read
    /// tab (a Markdown file) draws none; the unread tab's dot marks it. The
    /// mark changes with the newest notification, so its animation restarts;
    /// its color is the notification source's override, if any.
    /// - Parameter shownTab: the tab id a window shows in the pane; nil
    ///   falls back to ``shownTab(of:)``.
    func attentionMarks(for workspace: WorkspaceModel,
                        shownTab: @MainActor (PaneModel) -> String? = { _ in nil }) -> [LayoutPaneID: AttentionMark] {
        let attention = DesignSettings.shared.attention
        guard attention.style != .none, !preferences.mutedWorkspaces.contains(workspace.id) else { return [:] }
        let key = highlightKey(for: workspace)
        let dismissed = dismissedHighlights[key] ?? 0
        var marks: [LayoutPaneID: AttentionMark] = [:]
        for screen in workspace.screens {
            for pane in screen.panes {
                guard let id = shownTab(pane) ?? self.shownTab(of: pane), let shown = pane.tabs.first(where: { $0.id == id }) else { continue }
                // Each kind of pane rings only when its setting is on: terminals by default,
                // agent chats opt-in (`notifications.attention.agentChats`).
                let agentChat = shown.agentSession != nil
                guard attention.rings(agentChat: agentChat) else { continue }
                // An agent chat whose turn ended rings until the person goes into it.
                if key.machine == MachineRegistry.localID, let finished = agentFinished[shown.id] {
                    marks[LayoutPaneID(pane.id)] = AttentionMark(color: preferences.sources[.agent]?.color, generation: finished,
                                                                 agentChat: agentChat, quiet: quietAgentFinishes.contains(shown.id))
                    continue
                }
                guard let generation = unreadRing(of: shown, dismissed: dismissed) else { continue }
                // A marked tab with no notification has no source: the ring's own color.
                let color = shown.hasUnread ? preferences.sources[source(of: shown)]?.color : nil
                marks[LayoutPaneID(pane.id)] = AttentionMark(color: color, generation: generation, agentChat: agentChat)
            }
        }
        return marks
    }

    /// The generation of `tab`'s unread ring, or nil when it draws none: derived from the tab's
    /// unread state alone, so Mark as Unread rings and every read clears with no ring code of
    /// their own. An unread notification rings unless Dismiss Highlight hid it (`dismissed`, the
    /// workspace's newest dismissed notification id); a manual mark rings unless this mark was
    /// dismissed. A mark's generation sits above every notification id, so its ring restarts.
    func unreadRing(of tab: TabModel, dismissed: UInt64) -> UInt64? {
        guard tab.showsUnread else { return nil }
        if tab.hasUnread {
            let generation = tab.notification?.notification.rawValue ?? 1
            if generation > dismissed { return generation }
        }
        if tab.markedUnread, tab.markedUnreadGeneration > (dismissedMarks[highlightKey(for: tab)] ?? 0) {
            return Self.markRingBase | tab.markedUnreadGeneration
        }
        // An agent's "needs you here" mark (tab-attention-v1) rings until Dismiss Highlight hides
        // that request; a different owner-issued request rings again.
        guard tab.attention != nil,
              tab.attentionRingHiddenThrough.map({ $0 != tab.attentionGeneration }) ?? true else { return nil }
        return Self.markRingBase | Self.attentionRingBase | (tab.attentionGeneration & ~(Self.markRingBase | Self.attentionRingBase))
    }

    /// The bit a marked tab's ring generation carries, apart from notification ids.
    static let markRingBase: UInt64 = 1 << 63
    /// The bit an agent's attention ring carries, apart from manual marks.
    static let attentionRingBase: UInt64 = 1 << 62

    /// Of the panes in `removed` (their mark just went away), those read because
    /// the person went into them: their ring blinks out. Forgets the entry
    /// reads of every tab in `workspace`, so a later mark starts clean.
    func takeEntryReads(removed: Set<LayoutPaneID>, in workspace: WorkspaceModel) -> Set<LayoutPaneID> {
        guard !entryReads.isEmpty else { return [] }
        var entered: Set<LayoutPaneID> = []
        for pane in workspace.screens.flatMap(\.panes) {
            let read = pane.tabs.contains { entryReads.contains($0.id) }
            if read, removed.contains(LayoutPaneID(pane.id)) { entered.insert(LayoutPaneID(pane.id)) }
            for tab in pane.tabs { entryReads.remove(tab.id) }
        }
        return entered
    }

    /// The tab `pane` shows: the selection of the window that shows it, else the daemon's default tab.
    func shownTab(of pane: PaneModel) -> String? {
        if let selected = services?.paneController(for: pane)?.stripModel.selectedID { return selected.rawValue }
        guard !pane.tabs.isEmpty else { return nil }
        return pane.tabs[min(max(pane.defaultTabIndex, 0), pane.tabs.count - 1)].id
    }

    /// Whether `workspace` draws an attention ring now (the Dismiss Highlight item shows only then).
    func hasHighlight(_ workspace: WorkspaceModel) -> Bool {
        !attentionMarks(for: workspace).isEmpty
    }

    private func highlightKey(for workspace: WorkspaceModel) -> HighlightKey {
        let daemon = services?.machines.daemons.first { $0.store.workspace(id: workspace.id) === workspace }
        return HighlightKey(machine: daemon?.machineID ?? MachineRegistry.localID,
                            session: daemon?.identity?.session, id: workspace.id)
    }

    private func highlightKey(for tab: TabModel) -> HighlightKey {
        let daemon = services?.machines.daemon(forTab: tab)
        return HighlightKey(machine: daemon?.machineID ?? MachineRegistry.localID,
                            session: daemon?.identity?.session, id: tab.id)
    }

    /// Dismiss Highlight (cx-epgo): hides `workspace`'s attention rings
    /// until a newer notification arrives or a tab is marked unread again.
    /// The tabs stay unread (the tab dot, the row badge and the Dock badge
    /// keep them).
    func dismissHighlight(_ workspace: WorkspaceModel) {
        let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
        let newest = tabs.filter(\.hasUnread).map { $0.notification?.notification.rawValue ?? 1 }.max() ?? 0
        let key = highlightKey(for: workspace)
        // A restarted daemon has new notification IDs; discard only that machine's old session.
        dismissedHighlights = dismissedHighlights.filter { $0.key.machine != key.machine || $0.key.session == key.session }
        dismissedMarks = dismissedMarks.filter { $0.key.machine != key.machine || $0.key.session == key.session }
        if key.machine == MachineRegistry.localID {
            for tab in tabs where agentFinished[tab.id] != nil { agentFinished[tab.id] = nil; quietAgentFinishes.remove(tab.id) }
        }
        for tab in tabs where tab.markedUnread {
            dismissedMarks[highlightKey(for: tab)] = tab.markedUnreadGeneration
        }
        for tab in tabs where tab.attention != nil { tab.attentionRingHiddenThrough = tab.attentionGeneration }
        guard newest > (dismissedHighlights[key] ?? 0) else { return }
        dismissedHighlights[key] = newest
        note("highlight dismissed workspace=\(workspace.id) through=\(newest)")
    }
}
