#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextDaemon
public import CmuxNextOracle

/// The oracle's `notifications` facet (schemas/oracle/snapshot-v1.schema.json `notifications`): the
/// unread count the Dock badge shows, and per workspace its unread count and its Needs you. Counts only: a
/// notification's title and body never go in. Chromium's app badge is one number the badge manager keeps per app from
/// the model, never read back from the Dock (chrome/browser/badging/badge_manager.cc); this facet reads the daemon
/// store's mirrored counts and the agent lanes the same way, in the snapshot's main-actor turn, with no disk or
/// database read.
public nonisolated struct OracleNotificationsFacet: OracleFacetProvider {
    /// One workspace with something unread or something that needs you.
    public nonisolated struct Workspace: Sendable, Hashable {
        /// The public id (`ws_…`, as `snapshot.get` prints it).
        public var id: String
        /// What the workspace adds to the badge: its unread tabs, or 1 when it has none and is marked unread.
        public var unread: Int
        /// Its agent chats that wait on the person, the product's Needs you: a lane waiting on input, read or not.
        /// A failed turn is not one.
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
        /// counts them (`NotificationCenterService.unreadCount`), with each workspace's Needs you from `needsYou`.
        /// Nil while a workspace's tree is not mirrored: its unread count is the daemon's rollup, but no rollup says
        /// which of its chats wait, so the facet cannot give the state the person would see there.
        /// - Throws: A workspace with a count has no public id, so no schema id can name it.
        @MainActor public init?(store: DaemonStore, homeUnread: [String],
                                needsYou: (WorkspaceModel) -> Int) throws(OracleFacetError) {
            var workspaces: [Workspace] = []
            // A pending create's workspace is the app's overlay, not daemon state: nothing in it is unread yet.
            for workspace in store.workspaces where !workspace.isProvisional {
                guard !workspace.screens.isEmpty else { return nil }
                let tabs = workspace.unreadCount
                let unread = tabs == 0 && workspace.markedUnread ? 1 : tabs
                let asks = needsYou(workspace)
                guard unread > 0 || asks > 0 else { continue }
                guard let id = workspace.resourceID?.rawValue else {
                    throw OracleFacetError("workspace \(workspace.id) has \(unread) unread and \(asks) needs-you but no public id")
                }
                workspaces.append(Workspace(id: id, unread: unread, needsYou: asks))
            }
            self.init(unread: store.unreadBadge(homeUnread: homeUnread), workspaces: workspaces)
        }
    }

    public var facet: OracleFacet { .notifications }
    public let capture: OracleFacetCapture

    /// - Parameter read: The counts now, read in the snapshot's main-actor turn; nil when they cannot be compared
    ///   (``Reading/init(store:homeUnread:needsYou:)``).
    public init(read: @escaping @MainActor @Sendable () throws(OracleFacetError) -> Reading?) {
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in
            guard let reading = try read() else {
                return .notComparable(reason: "a workspace's tree is not mirrored, so its Needs you is unknown",
                                      task: OracleFacet.notifications.task)
            }
            return reading.value
        }
    }
}
#endif
