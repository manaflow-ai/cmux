import CmuxMobileModel
import CmuxMobileTransport
import Foundation

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

    public func setUnread(_ workspace: Workspace, _ unread: Bool) async throws {
        let client = try daemonClient(workspace.macID)
        try await metadata(client, workspace, ["marked_unread": unread])
        if !unread {
            for surface in Self.unreadSurfaces(of: workspace, in: sync.tree) {
                _ = try? WorkspaceSync.check(await client.request("ack-tab-notifications", params: ["surface": surface]))
            }
        }
        _ = try? await sync.listNow()
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
                throw WorkspaceCreationError("The Mac doesn't list this workspace's place yet. Try again in a moment.", isForPerson: true)
            }
            try await run(client, "set-personal-workspace", ["session_id": registry, "workspace_key": workspace.id, "index": index])
        } else {
            // The Mac's daemon order: the neighbour's index there.
            guard let position = visible.firstIndex(where: { $0.id == workspace.id }), visible.indices.contains(position + offset),
                  let target = sync.tree?.workspaces.firstIndex(where: { $0.id == visible[position + offset].id }) else {
                throw WorkspaceCreationError("The Mac doesn't list this workspace yet")
            }
            var params: [String: Any] = ["index": target]
            Self.address(workspace, into: &params)
            try await run(client, "move-workspace", params)
        }
        sync.invalidateArrangement()
        _ = try? await sync.listNow()
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

    /// The Mac's Mark All Notifications as Read (`markAllNotificationsRead`): each tab whose
    /// notification is unread is read with `ack-tab-notifications`, as the Mac's handler acks
    /// every unread tab. Its notifications stay in the ledger (Clear All removes them).
    public func markAllNotificationsRead(on macID: String) async throws -> Int {
        let client = try daemonClient(macID)
        let surfaces = Self.unreadNotificationSurfaces(sync.tree)
        for surface in surfaces {
            try await run(client, "ack-tab-notifications", ["surface": surface])
        }
        if !surfaces.isEmpty { _ = try? await sync.listNow() }
        return surfaces.count
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
