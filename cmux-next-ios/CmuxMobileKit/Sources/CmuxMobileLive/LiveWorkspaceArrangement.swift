import CmuxMobileModel
import CmuxMobileTransport
import Foundation
import OSLog

/// Pin, color, order, read marks and Clear All Notifications on the linked
/// Mac, with the commands the Mac's own sidebar sends (cmux-next-ios/SECURITY.md
/// "Workspace pins, order and Clear All Notifications"):
/// - Pin: `set-workspace-metadata {pinned: true}`. A Mac whose sidebar has
///   pinned tiles turns the flag into its tile (its legacy-pin migration).
/// - Unpin: `sidebar_layout.update {item.remove}` of the tile (else the flag off).
/// - Color: `set-workspace-metadata {color}` (a palette name, or null to reset).
/// - Move Up / Down: `set-personal-workspace {index}` in the person's order, or
///   `move-workspace {index}` on a Mac without personal order.
/// - Mark as Unread / Read: `set-workspace-metadata {marked_unread}`, and for
///   Read `ack-tab-notifications` on the workspace's unread tabs.
/// - Clear All Notifications: `notification.clear` (resource API).
extension LiveWorkspaceCreationBackend: WorkspaceArrangementBackend, NotificationClearing {
    public func canArrange(on macID: String) -> Bool { canManage(on: macID) }

    public func setPinned(_ workspace: Workspace, _ pinned: Bool) async throws {
        let client = try daemonClient(workspace.macID)
        if !pinned, let item = workspace.pinItemID {
            try await resource(client, "sidebar_layout.update", ["op": ["kind": "item.remove", "id": item]], key: "cmux-next-ios-unpin")
            // A flag the Mac has not turned into a tile yet goes too.
            if sync.tree?.legacyPinned.contains(workspace.id) == true {
                try await metadata(client, workspace, ["pinned": false])
            }
        } else {
            try await metadata(client, workspace, ["pinned": pinned])
        }
        sync.invalidateArrangement()
        _ = try? await sync.listNow()
    }

    public func setColor(_ workspace: Workspace, _ color: WorkspaceColor?) async throws {
        let client = try daemonClient(workspace.macID)
        try await metadata(client, workspace, ["color": color.map { $0.rawValue as Any } ?? NSNull()])
        _ = try? await sync.listNow()
    }

    /// Mark as Unread goes once. Mark as Read sticks (`StickyRead`): the phone already shows it
    /// read (`seenAt`), and while the Mac's daemon is down or restarting the write and the tabs'
    /// acks go again until it answers. It stops once the Mac's tree shows the workspace read, or
    /// gone, once the person marks it again, or once this phone no longer links that Mac.
    public func setUnread(_ workspace: Workspace, _ unread: Bool) async throws {
        let mark = (readMarks[workspace.id] ?? 0) + 1
        readMarks[workspace.id] = mark
        guard !unread else {
            let client = try daemonClient(workspace.macID)
            try await metadata(client, workspace, ["marked_unread": true])
            _ = try? await sync.listNow()
            return
        }
        let tabs = Self.unreadMarks(of: workspace, in: sync.tree)
        // The tree settles the read only once a try went: before it, a Mark as Unread still on its
        // way may not show there yet, and this read must still go after it.
        var tried = false
        do {
            _ = try await reads.send(stands: { readStands(workspace, mark: mark, settles: tried) }) {
                tried = true
                let client = try daemonClient(workspace.macID)
                var params: [String: Any] = ["marked_unread": false]
                Self.address(workspace, into: &params)
                try WorkspaceSync.check(await client.request("set-workspace-metadata", params: params, deadline: Self.readDeadline))
                try await acknowledge(Self.stillUnread(tabs, in: currentTree()), client: client)
            }
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
        _ = try? await sync.listNow()
    }

    /// The most a read's try waits for its answer: a daemon that went quiet is tried again.
    static let readDeadline: Duration = .seconds(15)

    /// Whether Mark as Read `mark` of `workspace` still stands: still the newest, its Mac still
    /// linked, and (when `settles` and this phone has the Mac's tree) the Mac still shows it unread.
    private func readStands(_ workspace: Workspace, mark: Int, settles: Bool) -> Bool {
        guard readMarks[workspace.id] == mark, link.target?.macID == workspace.macID else { return false }
        guard settles, let tree = sync.tree, sync.macID == workspace.macID else { return true }
        return tree.workspaces.first { $0.id == workspace.id }?.hasUnread == true
    }

    /// The Mac's tree as this try's connection lists it: one from before a reconnect may not show
    /// a notification that came meanwhile. A list that fails leaves the read unanswered.
    private func currentTree() async throws -> DaemonTree {
        do {
            return try await sync.listNow()
        } catch {
            throw LinkError(code: "no-tree", message: "The Mac's workspaces are not listed yet")
        }
    }

    /// `ack-tab-notifications` for each of `surfaces`. A tab the Mac refuses (closed meanwhile)
    /// is left; an unanswered one throws, so the read goes again.
    private func acknowledge(_ surfaces: [Int], client: DaemonClient) async throws {
        for surface in surfaces {
            do {
                try WorkspaceSync.check(await client.request("ack-tab-notifications", params: ["surface": surface], deadline: Self.readDeadline))
            } catch is DaemonReplyError {
                continue
            }
        }
    }

    /// A tab a read covers: its surface and the unread notification it showed (nil: no marker).
    struct UnreadMark: Equatable, Sendable {
        var surface: Int
        var notification: Int?
        /// When that notification was posted: a daemon that restarted numbers its markers anew,
        /// and the time still names the same one.
        var createdAt: Date?

        init(surface: Int, marker: DaemonTree.NotificationMarker?) {
            self.surface = surface
            notification = marker.flatMap { $0.unread ? $0.notification : nil }
            createdAt = marker.flatMap { $0.unread ? $0.createdAt : nil }
        }

        /// Whether `marker` still shows the notification read here unread (not a newer one).
        func isStill(_ marker: DaemonTree.NotificationMarker?) -> Bool {
            guard let marker, marker.unread else { return false }
            if let createdAt, let now = marker.createdAt { return now <= createdAt }
            return marker.notification == notification
        }
    }

    /// `unreadSurfaces` with the notification each one showed.
    nonisolated static func unreadMarks(of workspace: Workspace, in tree: DaemonTree?) -> [UnreadMark] {
        unreadSurfaces(of: workspace, in: tree).map { UnreadMark(surface: $0, marker: tree?.notificationMarkers[$0]) }
    }

    /// The tabs of `marks` still to read in `tree` (all of them while there is none): one read
    /// meanwhile, or showing a newer notification than the one read, is left (the person has
    /// not seen a newer one).
    nonisolated static func stillUnread(_ marks: [UnreadMark], in tree: DaemonTree?) -> [Int] {
        guard let tree else { return marks.map(\.surface) }
        return marks.compactMap { mark in
            let marker = tree.notificationMarkers[mark.surface]
            guard mark.notification != nil else { return marker?.unread == true ? nil : mark.surface }
            return mark.isStill(marker) ? mark.surface : nil
        }
    }

    /// The workspace's tabs the Mac shows unread; all of them when the Mac says
    /// the workspace is unread but no tab carries a marker (the Mac's `acknowledge`).
    nonisolated static func unreadSurfaces(of workspace: Workspace, in tree: DaemonTree?) -> [Int] {
        guard let tree else { return [] }
        let surfaces = workspace.tabs.compactMap { tree.surfaces[$0.id] }
        let unread = surfaces.filter { tree.notificationMarkers[$0]?.unread == true }
        return unread.isEmpty && workspace.hasUnread ? surfaces : unread
    }

    public func move(_ workspace: Workspace, by offset: Int, among visible: [Workspace]) async throws {
        let client = try daemonClient(workspace.macID)
        if let arrangement = sync.arrangement, arrangement.rows != nil, let registry = sync.tree?.registryID {
            guard let index = arrangement.personalIndex(moving: workspace, by: offset, among: visible, registryID: registry) else {
                throw WorkspaceCreationError("The Mac doesn't list this workspace's place. Try again in a moment.", isForPerson: true)
            }
            try await run(client, "set-personal-workspace", ["session_id": registry, "workspace_key": workspace.id, "index": index])
        } else {
            // The Mac's daemon order: the neighbour's index there.
            guard let position = visible.firstIndex(where: { $0.id == workspace.id }), visible.indices.contains(position + offset),
                  let target = sync.tree?.workspaces.firstIndex(where: { $0.id == visible[position + offset].id }) else {
                throw WorkspaceCreationError("The Mac doesn't list this workspace")
            }
            var params: [String: Any] = ["index": target]
            Self.address(workspace, into: &params)
            try await run(client, "move-workspace", params)
        }
        sync.invalidateArrangement()
        _ = try? await sync.listNow()
    }

    /// Move Workspace to Top / to Bottom and each step of Sort Workspaces: the Mac's
    /// `set-personal-workspace {index}` right before or after `anchor` in the person's order,
    /// or `move-workspace {index}` to the anchor's place on a Mac without personal order.
    public func place(_ workspace: Workspace, next anchor: Workspace, after: Bool) async throws {
        let client = try daemonClient(workspace.macID)
        if let arrangement = sync.arrangement, arrangement.rows != nil, let registry = sync.tree?.registryID {
            guard let index = arrangement.personalIndex(placing: workspace, next: anchor, after: after, registryID: registry) else {
                throw WorkspaceCreationError("The Mac doesn't list this workspace's place. Try again in a moment.", isForPerson: true)
            }
            // The next step of a sort reads the order this move made (the list below reads it again).
            try await run(client, "set-personal-workspace", ["session_id": registry, "workspace_key": workspace.id, "index": index])
        } else {
            guard let tree = sync.tree, let from = tree.workspaces.firstIndex(where: { $0.id == workspace.id }),
                  let to = tree.workspaces.firstIndex(where: { $0.id == anchor.id }) else {
                throw WorkspaceCreationError("The Mac doesn't list this workspace")
            }
            // The daemon's index counts the list with the workspace still in it.
            let index = Self.daemonIndex(from: from, anchor: to, after: after)
            var params: [String: Any] = ["index": index]
            Self.address(workspace, into: &params)
            try await run(client, "move-workspace", params)
            _ = try? await sync.listNow()
            return
        }
        sync.invalidateArrangement()
        _ = try? await sync.listNow()
    }

    /// `move-workspace`'s index for a workspace at `from` going right before or after the row at
    /// `anchor` (indices in the list that still holds it).
    nonisolated static func daemonIndex(from: Int, anchor: Int, after: Bool) -> Int {
        let target = after ? anchor + 1 : anchor
        return target > from ? target - 1 : target
    }

    public func setIcon(_ workspace: Workspace, _ icon: String?) async throws {
        let client = try daemonClient(workspace.macID)
        try await metadata(client, workspace, ["icon": icon.map { $0 as Any } ?? NSNull()])
        _ = try? await sync.listNow()
    }

    /// The Mac's Clear Workspace Name: its `title` (the display name) cleared.
    public func clearName(_ workspace: Workspace) async throws {
        let client = try daemonClient(workspace.macID)
        try await metadata(client, workspace, ["title": NSNull()])
        _ = try? await sync.listNow()
    }

    public func canClearNotifications(on macID: String) -> Bool { canManage(on: macID) }

    public func clearAllNotifications(on macID: String) async throws {
        let client = try daemonClient(macID)
        try await resource(client, "notification.clear", [:], key: "cmux-next-ios-notification-clear")
    }

    /// Mark All works while this Mac is linked, also while its daemon is down or reconnecting:
    /// its reads wait for it (`StickyRead`).
    public func canMarkAllNotificationsRead(on macID: String) -> Bool { link.target?.macID == macID }

    /// The Mac's Mark All Notifications as Read (`markAllNotificationsRead`): each tab whose
    /// notification is unread is read with `ack-tab-notifications`, as the Mac's handler acks
    /// every unread tab. Its notifications stay in the ledger (Clear All removes them).
    ///
    /// The tabs are the ones the Mac's last tree showed unread, read on in the background until
    /// the Mac answers (`StickyRead`): a Mac whose daemon is down, restarting or silent never
    /// makes another linked Mac's read wait. Returns how many tabs it reads.
    public func markAllNotificationsRead(on macID: String) async throws -> Int {
        guard canMarkAllNotificationsRead(on: macID) else { throw WorkspaceCreationError("Not connected") }
        let tree = sync.macID == macID ? sync.tree : nil
        let marks = Self.unreadNotificationSurfaces(tree).map { UnreadMark(surface: $0, marker: tree?.notificationMarkers[$0]) }
        guard !marks.isEmpty else { return 0 }
        let reads = reads
        // task-owner: one Mark All the person made, sent again while this Mac is unanswered; ends
        // on its answer, a refusal, every tab settled, or this backend or its Mac gone
        Task { [weak self] in
            do {
                _ = try await reads.send(stands: { self?.markAllStands(marks, on: macID) == true }) {
                    guard let self else { throw CancellationError() }
                    let client = try self.daemonClient(macID)
                    try await self.acknowledgeAll(Self.stillUnread(marks, in: self.currentTree()), client: client)
                }
            } catch {
                creationLog.error("Mark All Notifications as Read refused: \(String(describing: error), privacy: .public)")
            }
            _ = try? await self?.sync.listNow()
        }
        return marks.count
    }

    /// Mark All's acks: the first refusal stops it, as before.
    private func acknowledgeAll(_ surfaces: [Int], client: DaemonClient) async throws {
        for surface in surfaces {
            try WorkspaceSync.check(await client.request("ack-tab-notifications", params: ["surface": surface], deadline: Self.readDeadline))
        }
    }

    /// Whether Mark All on `macID` still has a tab to read and its Mac is still linked.
    private func markAllStands(_ marks: [UnreadMark], on macID: String) -> Bool {
        link.target?.macID == macID && (sync.macID != macID || !Self.stillUnread(marks, in: sync.tree).isEmpty)
    }

    /// Every tab the Mac shows with an unread notification, in surface order.
    nonisolated static func unreadNotificationSurfaces(_ tree: DaemonTree?) -> [Int] {
        (tree?.notificationMarkers ?? [:]).filter(\.value.unread).map(\.key).sorted()
    }

    // MARK: Lines

    func daemonClient(_ macID: String) throws -> DaemonClient {
        guard canManage(on: macID), let client = sync.daemon else { throw WorkspaceCreationError("Not connected") }
        return client
    }

    /// Workspaces are addressed by key; a tree without keys gave "w<id>".
    nonisolated static func address(_ workspace: Workspace, into params: inout [String: Any]) {
        if workspace.id.hasPrefix("w"), let id = Int(workspace.id.dropFirst()) {
            params["workspace"] = id
        } else {
            params["key"] = workspace.id
        }
    }

    private func metadata(_ client: DaemonClient, _ workspace: Workspace, _ fields: [String: Any]) async throws {
        var params = fields
        Self.address(workspace, into: &params)
        try await run(client, "set-workspace-metadata", params)
    }

    private func run(_ client: DaemonClient, _ command: String, _ params: sending [String: Any]) async throws {
        do {
            try WorkspaceSync.check(await client.request(command, params: params))
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// Sends one `cmux.protocol/2` mutation and returns its response object.
    @discardableResult
    func resource(_ client: DaemonClient, _ operation: String, _ params: sending [String: Any], key: String) async throws -> [String: Any] {
        do {
            let line = try await client.resourceRequest(operation, params: params, idempotencyKey: "\(key)-\(UUID().uuidString.lowercased())",
                                                        deadline: .seconds(15))
            return try WorkspaceSync.checkResource(line)
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }
}
