import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextBridge
import CmuxNextSettings

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

    /// The content tab of the window whose focus owns `window` (a Chromium
    /// page window resolves to its cmux window).
    func focusedTab(in window: NSWindow?) -> String? {
        guard let services, let window = CmuxApplication.accessibilityWindow(for: window) else { return nil }
        let controller = services.windows.controllers.first { $0.window === window }
        return controller.flatMap { Self.contentTab($0.focus.state.resolved) }
    }

    /// `window`'s focus is a terminal (not a page, address bar, or find bar).
    func isTerminalFocused(in window: NSWindow?) -> Bool {
        guard let services, let window = CmuxApplication.accessibilityWindow(for: window),
              let controller = services.windows.controllers.first(where: { $0.window === window }) else { return false }
        if case .terminal = controller.focus.state.resolved { return true }
        return false
    }

    /// The tab is the focused content of the key window while cmux is active.
    func isViewed(_ tabID: String) -> Bool {
        guard let services, NSApp.isActive else { return false }
        return services.windows.controllers.contains { controller in
            controller.focus.state.windowKey && Self.contentTab(controller.focus.state.resolved) == tabID
        }
    }

    static func tab(id: String, in store: DaemonStore) -> TabModel? {
        for workspace in store.workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    if let tab = pane.tabs.first(where: { $0.id == id }) { return tab }
                }
            }
        }
        return nil
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
    static func unreadCount(_ store: DaemonStore?, homeUnread: [String] = []) -> Int {
        let workspaces = store?.workspaces ?? []
        let tabs = workspaces.reduce(0) { total, workspace in
            let count = workspace.unreadCount
            return total + (count == 0 && workspace.markedUnread ? 1 : count)
        }
        guard !homeUnread.isEmpty else { return tabs }
        var counted = Set<String>()
        for workspace in workspaces {
            for screen in workspace.screens {
                for pane in screen.panes {
                    for tab in pane.tabs where tab.hasUnread {
                        if let id = tab.snapshot.conversation?.conversation, tab.kind == .conversation { counted.insert(id) }
                    }
                }
            }
        }
        return tabs + Set(homeUnread).subtracting(counted).count
    }

    /// The badge count now: the store's unread tabs and Home's unread conversations.
    func currentUnreadCount() -> Int {
        let rows = services?.home.homeStore.rows ?? []
        return Self.unreadCount(services?.daemon.store, homeUnread: rows.filter { $0.unread > 0 }.map(\.id.rawValue))
    }

    /// Sets the Dock tile's unread count. Compares with the label it set
    /// last: reading `dockTile.badgeLabel` asks the Dock and can block.
    func updateDockBadge(_ count: Int) {
        let label = preferences.dockBadge && count > 0 ? String(count) : nil
        guard label != dockBadgeLabel else { return }
        dockBadgeLabel = label
        NSApp.dockTile.badgeLabel = label
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
                serves: { daemon.isLocal && daemon.identity?.supports(DaemonCapabilities.shared.feedLocalOwner) == true },
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
    /// matched by durable key and by public id (`ws_…`, an item's context).
    func feedHandoffPolicy() -> FeedHandoffPolicy {
        var muted = preferences.mutedWorkspaces
        for workspace in services?.daemon.store.workspaces ?? [] where muted.contains(workspace.id) {
            if let resource = workspace.resourceID { muted.insert(resource.rawValue) }
        }
        return FeedHandoffPolicy(preferences: preferences, mutedWorkspaces: muted)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// Attention marks for `workspace`'s panes: every pane with an unread
    /// tab, unless the workspace is muted or the style is `none`. The mark
    /// changes with the newest notification, so its animation restarts;
    /// its color is the notification source's override, if any.
    func attentionMarks(for workspace: WorkspaceModel) -> [LayoutPaneID: AttentionMark] {
        guard DesignSettings.shared.attention.style != .none, !preferences.mutedWorkspaces.contains(workspace.id) else { return [:] }
        let sameSession = dismissedHighlightSession == services?.daemon.identity?.session
        let dismissed = sameSession ? dismissedHighlights[workspace.id] ?? 0 : 0
        var marks: [LayoutPaneID: AttentionMark] = [:]
        for screen in workspace.screens {
            for pane in screen.panes {
                let unread = pane.tabs.filter(\.hasUnread)
                guard let newest = unread.max(by: { ($0.notification?.notification.rawValue ?? 0) < ($1.notification?.notification.rawValue ?? 0) }) else { continue }
                let generation = newest.notification?.notification.rawValue ?? 1
                // A dismissed highlight stays hidden until a newer notification arrives.
                guard generation > dismissed else { continue }
                let color = preferences.sources[source(of: newest)]?.color
                marks[LayoutPaneID(pane.id)] = AttentionMark(color: color, generation: generation)
            }
        }
        return marks
    }

    /// Whether `workspace` draws an attention ring now (the Dismiss Highlight item shows only then).
    func hasHighlight(_ workspace: WorkspaceModel) -> Bool {
        !attentionMarks(for: workspace).isEmpty
    }

    /// Dismiss Highlight (cx-epgo): hides `workspace`'s attention rings
    /// until a newer notification arrives. The notifications stay unread
    /// (the tab mark, the row badge and the Dock badge keep them).
    func dismissHighlight(_ workspace: WorkspaceModel) {
        let newest = workspace.screens.flatMap(\.panes).flatMap(\.tabs).filter(\.hasUnread)
            .map { $0.notification?.notification.rawValue ?? 1 }.max() ?? 0
        let session = services?.daemon.identity?.session
        if session != dismissedHighlightSession {
            dismissedHighlights = [:]
            dismissedHighlightSession = session
        }
        guard newest > (dismissedHighlights[workspace.id] ?? 0) else { return }
        dismissedHighlights[workspace.id] = newest
        note("highlight dismissed workspace=\(workspace.id) through=\(newest)")
    }
}
