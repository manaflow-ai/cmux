public import CmuxNextDaemon

/// The daemon writes that change tab group membership, one path for every entrypoint: the
/// strip's gestures (`PaneController.handleGroup`, a drag into a group, a dragged selection)
/// and every action (`TabGroupHandlers`: the tab menu, the palette, shortcuts, the CLI, MCP).
/// A pane on a daemon with state resources writes through `connection.state`; otherwise the
/// surface commands. Each method returns the request body the caller's runner sends.
///
/// ```swift
/// let writes = TabGroupWrites(pane: pane, daemon: daemon)
/// _ = await daemon.runGroupCommand("create-tab-group", intent: nil, writes.create(tabs, name: nil, color: "blue"))
/// ```
public struct TabGroupWrites: Sendable {
    /// A request the caller's group command runner sends on the pane's connection.
    public typealias Body = @Sendable (DaemonConnection, ClientTransactionID) async throws -> Void

    /// Whether `pane`'s daemon takes group writes as state resources.
    public let usesStateResources: Bool
    /// The pane the writes act in (surface commands only).
    public let paneHandle: PaneID

    /// The open groups `tab` can join: every group of its machine's `store` but its own. Add Tab
    /// to Group… lists them; with none it says why, instead of asking for a group from an empty list.
    ///
    /// - Parameters:
    ///   - tab: The tab that would join.
    ///   - store: The store of `tab`'s own machine.
    /// - Returns: The groups, in workspace, pane and strip order.
    @MainActor public static func joinable(by tab: TabModel, in store: DaemonStore) -> [TabGroupModel] {
        store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabGroups).filter { $0.id != tab.tabGroup }
    }

    /// Why Add Tab to Group… cannot ask `tab` for a group: no group of its machine's `store` to
    /// join (``joinable(by:in:)``). Nil when there is one.
    @MainActor public static func joinRefusal(for tab: TabModel, in store: DaemonStore) -> String? {
        joinable(by: tab, in: store).isEmpty ? RefusalStrings.noTabGroupToJoin : nil
    }

    /// - Parameters:
    ///   - pane: The pane the tabs and the group are in.
    ///   - daemon: `pane`'s own daemon.
    @MainActor public init(pane: PaneModel, daemon: DaemonService) {
        usesStateResources = daemon.store.servesStateResources && pane.resourceID != nil
        paneHandle = pane.handle
    }

    /// A new group of `tabs` (pinned tabs left out by the caller).
    ///
    /// - Parameters:
    ///   - tabs: The tabs, in display order.
    ///   - name: The group's name; nil leaves it unnamed.
    ///   - color: The group's color token.
    /// - Returns: The request that creates the group.
    public func create(_ tabs: [TabModel], name: String?, color: String) -> Body {
        let surfaces = tabs.map(\.surface), resources = tabs.compactMap(\.resourceID)
        let state = usesStateResources && resources.count == surfaces.count && !resources.isEmpty, handle = paneHandle
        return { connection, transaction in
            if state {
                _ = try await connection.state.createTabGroup(tabs: resources, name: name, color: color)
                return
            }
            _ = try await connection.createTabGroup(in: handle, tabs: surfaces, name: name, color: color, transaction: transaction)
        }
    }

    /// `tabs` join `group` at `index` (a group position; nil appends).
    ///
    /// - Parameters:
    ///   - tabs: The tabs that join, in order.
    ///   - group: The group they join.
    ///   - index: Their position among the group's tabs; nil appends.
    /// - Returns: The request that adds the tabs.
    public func add(_ tabs: [TabModel], to group: TabGroupID, index: Int? = nil) -> Body {
        let surfaces = tabs.map(\.surface), resources = tabs.compactMap(\.resourceID)
        let state = usesStateResources && resources.count == surfaces.count && !resources.isEmpty
        return { connection, transaction in
            if state { return try await connection.state.addTabs(resources, toTabGroup: group.rawValue, index: index) }
            _ = try await connection.addTabs(surfaces, toGroup: group, index: index, transaction: transaction)
        }
    }

    /// `tabs` leave their groups.
    ///
    /// - Parameter tabs: The tabs that leave.
    /// - Returns: The request that removes the tabs from their groups.
    public func remove(_ tabs: [TabModel]) -> Body {
        let surfaces = tabs.map(\.surface), resources = tabs.compactMap(\.resourceID)
        let state = usesStateResources && resources.count == surfaces.count && !resources.isEmpty
        return { connection, transaction in
            if state { return try await connection.state.removeTabsFromTabGroup(resources) }
            _ = try await connection.removeTabsFromGroup(surfaces, transaction: transaction)
        }
    }
}
