import AppKit
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextBridge
import CmuxNextSettings

/// Tab lookups, the dock badge and the pane attention marks.
extension NotificationCenterService {
    /// The tab `resolved` types into: a terminal or a page (with its bars).
    static func contentTab(_ resolved: FocusState.Resolved) -> String? {
        switch resolved {
        case .terminal(_, let tab), .browserPage(_, let tab), .addressBar(_, let tab), .findBar(_, let tab), .devTools(_, let tab): tab
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

    static func unreadCount(_ store: DaemonStore?) -> Int {
        store?.workspaces.reduce(0) { $0 + $1.unreadCount } ?? 0
    }

    /// Sets the Dock tile's unread count. Compares with the label it set
    /// last: reading `dockTile.badgeLabel` asks the Dock and can block.
    func updateDockBadge(_ count: Int) {
        let label = preferences.dockBadge && count > 0 ? String(count) : nil
        guard label != dockBadgeLabel else { return }
        dockBadgeLabel = label
        NSApp.dockTile.badgeLabel = label
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
