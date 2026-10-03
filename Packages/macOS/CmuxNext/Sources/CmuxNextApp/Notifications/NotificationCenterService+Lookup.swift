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
             .agentPage(_, let tab), .page(_, let tab): tab
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
    static func unreadCount(_ store: DaemonStore?) -> Int {
        store?.workspaces.reduce(0) { total, workspace in
            let count = workspace.unreadCount
            return total + (count == 0 && workspace.markedUnread ? 1 : count)
        } ?? 0
    }

    /// Sets the Dock tile's unread count. Compares with the label it set
    /// last: reading `dockTile.badgeLabel` asks the Dock and can block.
    func updateDockBadge(_ count: Int) {
        let label = preferences.dockBadge && count > 0 ? String(count) : nil
        guard label != dockBadgeLabel else { return }
        dockBadgeLabel = label
        NSApp.dockTile.badgeLabel = label
    }

    /// The feed bridge over `feed`'s owner calls (nil without a feed service).
    static func makeFeedBridge(_ feed: FeedService?) -> FeedNotificationBridge? {
        guard let feed else { return nil }
        return FeedNotificationBridge(
            owner: { [weak feed] path, body in
                guard let feed else { throw FeedServiceError.signedOut }
                return try await feed.call(path, body)
            },
            isSignedIn: { [weak feed] in feed?.isSignedIn ?? false }
        )
    }

    /// Which path copies notifications into the feed (B1): the handoff
    /// driver when the local daemon serves `feed-local-owner-v1` (and the
    /// app can adopt), else the step-1 bridge (older and remote daemons).
    enum FeedPath: Equatable { case bridge, handoff }

    static func feedPath(driver: FeedHandoffDriver?) -> FeedPath {
        driver?.isActive == true ? .handoff : .bridge
    }

    /// The handoff driver over the local daemon and `feed`'s owner calls
    /// (nil without a feed service).
    func makeFeedDriver(_ services: AppServices) -> FeedHandoffDriver? {
        guard let feed = services.feed else { return nil }
        let daemon = services.daemon
        func connection() throws -> DaemonConnection {
            guard let connection = daemon.connection else { throw DaemonError.notConnected }
            return connection
        }
        return FeedHandoffDriver(
            daemon: .init(
                serves: { daemon.isLocal && daemon.identity?.supports(DaemonCapabilities.shared.feedLocalOwner) == true },
                list: { state, unread in try await connection().feedLocalList(state: state, unread: unread) },
                begin: { try await connection().feedLocalHandoffBegin($0) },
                done: { try await connection().feedLocalHandoffDone($0, home: $1) }),
            owner: { [weak feed] path, body in
                guard let feed else { throw FeedServiceError.signedOut }
                return try await feed.call(path, body)
            },
            isSignedIn: { [weak feed] in feed?.isSignedIn ?? false },
            installID: { [weak feed] in feed?.installID },
            policy: { [weak self] in self?.feedHandoffPolicy() ?? FeedHandoffPolicy(preferences: .init(), mutedWorkspaces: []) })
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

    /// Posts `notification` to the feed as a notice (local daemon only), as
    /// far as `feed.mirrorNotifications` allows for its source.
    func mirrorToFeed(_ notification: DaemonNotification, source: NotificationSource, located: LocatedTab) {
        guard let feedBridge, let session = services?.daemon.identity?.session, !session.isEmpty,
              let content = Self.feedContent(notification, source: source, mirror: preferences.feedMirror) else { return }
        feedBridge.post(.init(
            notification: notification.notification.rawValue, daemonSession: session,
            title: content.title, body: content.body, level: notification.level,
            tab: located.tab.id, workspace: located.workspace.id, label: source.rawValue
        ))
    }

    /// What `feed.mirrorNotifications` lets leave the Mac: nil for nothing.
    /// The tab title is never sent (it can hold a command line).
    nonisolated static func feedContent(_ notification: DaemonNotification, source: NotificationSource,
                                        mirror: FeedMirrorPreferences) -> (title: String, body: String)? {
        switch source {
        case .terminal:
            switch mirror.terminal {
            case .off: return nil
            case .title: return (notification.title, "")
            case .full: return (notification.title, notification.body)
            }
        default:
            return mirror.agents ? (notification.title, notification.body) : nil
        }
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
        var marks: [LayoutPaneID: AttentionMark] = [:]
        for screen in workspace.screens {
            for pane in screen.panes {
                let unread = pane.tabs.filter(\.hasUnread)
                guard let newest = unread.max(by: { ($0.notification?.notification.rawValue ?? 0) < ($1.notification?.notification.rawValue ?? 0) }) else { continue }
                let color = preferences.sources[source(of: newest)]?.color
                marks[LayoutPaneID(pane.id)] = AttentionMark(color: color, generation: newest.notification?.notification.rawValue ?? 1)
            }
        }
        return marks
    }
}
