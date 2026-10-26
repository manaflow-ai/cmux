#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextDaemon
public import CmuxNextOracle

/// The oracle's `notifications` facet (p15-oracle-042, schemas/oracle/snapshot-v1.schema.json `notifications`): the
/// unread count the Dock badge shows, and per workspace its unread count and how many of its tabs need you. Counts
/// only: a notification's title and body never go in. Chromium's app badge is one number the badge manager keeps per
/// app from the model, never read back from the Dock (chrome/browser/badging/badge_manager.cc); this facet reads the
/// daemon store's mirrored counts the same way, in the snapshot's main-actor turn, with no disk or database read.
public nonisolated struct OracleNotificationsFacet: OracleFacetProvider {
    /// One workspace with something unread or something that needs you.
    public nonisolated struct Workspace: Sendable, Hashable {
        /// The public id (`ws_…`, as `snapshot.get` prints it).
        public var id: String
        /// What the workspace adds to the badge: its unread tabs, or 1 when it has none and is marked unread.
        public var unread: Int
        /// Its tabs whose unread notification is an ask (an approval, a question, a plan review: a warning) or an
        /// error, the notifications that wait on the person (`TabModel.holdsUnreadAsk`).
        public var needsYou: Int

        public init(id: String, unread: Int, needsYou: Int) {
            self.id = id
            self.unread = unread
            self.needsYou = needsYou
        }

        public var value: OracleValue {
            ["workspace": .string(id), "unread": OracleValue(unread), "needsYou": OracleValue(needsYou)]
        }
    }

    /// The counts now.
    public nonisolated struct Reading: Sendable, Hashable {
        /// The Dock badge (`DaemonStore.unreadBadge`): the workspaces' unread count and Home's unread conversations
        /// that no workspace tab already counts.
        public var unread: Int
        /// The workspaces with a nonzero count, in the store's order.
        public var workspaces: [Workspace]

        public var needsYou: Int { workspaces.reduce(0) { $0 + $1.needsYou } }

        public var value: OracleValue {
            ["unread": OracleValue(unread), "needsYou": OracleValue(needsYou), "workspaces": .array(workspaces.map(\.value))]
        }

        public init(unread: Int, workspaces: [Workspace]) {
            self.unread = unread
            self.workspaces = workspaces
        }

        /// The counts of `store` and Home's unread conversations (`homeUnread`, conversation ids), as the Dock badge
        /// counts them (`NotificationCenterService.unreadCount`).
        @MainActor public init(store: DaemonStore, homeUnread: [String]) {
            unread = store.unreadBadge(homeUnread: homeUnread)
            workspaces = store.workspaces.compactMap { workspace in
                let tabs = workspace.unreadCount
                let unread = tabs == 0 && workspace.markedUnread ? 1 : tabs
                var needsYou = 0
                for screen in workspace.screens {
                    for pane in screen.panes { needsYou += pane.tabs.reduce(0) { $0 + (Self.asks($1) ? 1 : 0) } }
                }
                guard unread > 0 || needsYou > 0 else { return nil }
                return Workspace(id: workspace.resourceID?.rawValue ?? workspace.id, unread: unread, needsYou: needsYou)
            }
        }

        /// The tab's unread notification is a warning or an error, still to be seen.
        @MainActor private static func asks(_ tab: TabModel) -> Bool {
            guard tab.hasUnread, let level = tab.notification?.level else { return false }
            return level == .warning || level == .error
        }
    }

    public var facet: OracleFacet { .notifications }
    public let capture: OracleFacetCapture

    /// - Parameter read: The counts now, read in the snapshot's main-actor turn.
    public init(read: @escaping @MainActor @Sendable () throws(OracleFacetError) -> Reading) {
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in try read().value }
    }
}
#endif
