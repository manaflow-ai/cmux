import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

/// The one mutation path for screen groups (`screen-groups-v1`), shared by
/// the screen bar's chips and editor bubble, the palette, context menus,
/// shortcuts, and the CLI. Each change is one daemon command: the v2
/// `screen_group.*` operations on a daemon with state resources; group
/// moves and saved groups have no daemon operation there
/// (`DaemonCapabilities.savedScreenGroups`).
@MainActor
enum ScreenGroupCommands {
    /// Public ids of `screens` when their daemon takes the v2 operations.
    private static func stateIDs(_ screens: [ScreenModel], _ daemon: DaemonService) -> [ResourceID]? {
        guard daemon.store.servesStateResources else { return nil }
        let ids = screens.compactMap(\.resourceID)
        return ids.count == screens.count && !ids.isEmpty ? ids : nil
    }

    static func create(_ screens: [ScreenModel], in workspace: WorkspaceModel, name: String?, color: GroupColor?, daemon: DaemonService) {
        let handles = screens.map(\.handle), color = (color ?? nextColor(in: workspace)).rawValue, ids = stateIDs(screens, daemon)
        daemon.send("create-screen-group") {
            if let ids { _ = try await $0.createScreenGroup(screens: ids, name: name, color: color); return }
            _ = try await $0.createScreenGroup(handles, name: name, color: color)
        }
    }

    static func add(_ screens: [ScreenModel], to group: ScreenGroupID, index: Int? = nil, daemon: DaemonService) {
        let handles = screens.map(\.handle), ids = stateIDs(screens, daemon)
        daemon.send("add-screens-to-screen-group") {
            if let ids { return try await $0.addScreens(ids, toScreenGroup: group.rawValue) }
            _ = try await $0.addScreens(handles, toGroup: group, index: index)
        }
    }

    static func remove(_ screens: [ScreenModel], daemon: DaemonService) {
        let handles = screens.map(\.handle), ids = stateIDs(screens, daemon)
        daemon.send("remove-screens-from-screen-group") {
            if let ids { return try await $0.removeScreensFromScreenGroup(ids) }
            _ = try await $0.removeScreensFromGroup(handles)
        }
    }

    static func update(_ group: ScreenGroupID, name: String? = nil, color: GroupColor? = nil, collapsed: Bool? = nil, daemon: DaemonService) {
        let color = color?.rawValue, state = daemon.store.servesStateResources
        daemon.send("update-screen-group") {
            if state { return try await $0.updateScreenGroup(group.rawValue, name: name, color: color, collapsed: collapsed) }
            _ = try await $0.updateScreenGroup(group, name: name, color: color, collapsed: collapsed)
        }
    }

    /// Collapses or expands. Collapsing a group that holds the shown screen
    /// first shows the nearest screen outside it (Chrome's rule).
    static func setCollapsed(_ ref: ScreenGroupRef, _ collapsed: Bool) {
        if collapsed, let content = ref.content, let active = content.layoutModel.activeScreenID?.rawValue,
           ref.members.contains(where: { $0.id == active }),
           let outside = ref.workspace.screens.first(where: { $0.group != ref.group.id }) {
            ScreenCommands.select(LayoutScreenID(outside.id), in: content)
        }
        update(ref.group.id, collapsed: collapsed, daemon: ref.daemon)
    }

    static func move(_ group: ScreenGroupID, to index: Int, daemon: DaemonService) {
        daemon.send("move-screen-group") { _ = try await $0.moveScreenGroup(group, to: index) }
    }

    static func move(_ group: ScreenGroupID, toWorkspace target: WorkspaceModel, daemon: DaemonService, services: AppServices) {
        let source = daemon.store.workspaces.first { $0.screenGroups.contains { $0.id == group } }?.id
        guard !services.windows.crossesIncognito(from: source, to: target.id) else {
            return services.registry.refuse(RefusalStrings.incognitoMismatch)
        }
        let workspace = target.handle
        daemon.send("move-screen-group") { _ = try await $0.moveScreenGroup(group, to: nil, workspace: workspace) }
    }

    static func moveToNewWorkspace(_ group: ScreenGroupID, daemon: DaemonService, services: AppServices, newWindow: Bool) {
        guard let connection = daemon.connection else { return }
        let state = services.windows.active?.state
        let origin = services.windows.moveOrigin(of: daemon.store.workspaces.first { $0.screenGroups.contains { $0.id == group } }?.id)
        Task {
            do {
                let result = try await connection.moveScreenGroup(group, to: nil, newWorkspace: true)
                guard let key = result.key?.rawValue else { return }
                services.windows.placeMoved(key, from: origin, preferred: state, newWindow: newWindow)
            } catch {
                daemon.logger.error("move-screen-group new_workspace failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    static func ungroup(_ group: ScreenGroupID, daemon: DaemonService) {
        let state = daemon.store.servesStateResources
        daemon.send("ungroup-screen-group") {
            if state { return try await $0.ungroupScreenGroup(group.rawValue) }
            _ = try await $0.ungroupScreenGroup(group)
        }
    }

    /// Closes the group's screens: one `close-screen` each on a daemon with
    /// state resources (no v2 group close), else `close-screen-group`.
    static func close(_ ref: ScreenGroupRef, services: AppServices) {
        if ref.daemon.store.servesStateResources {
            return ScreenCommands.close(ref.members, in: ref.workspace, daemon: ref.daemon, services: services)
        }
        for screen in ref.members { services.closedScreens.record(screen, in: ref.workspace, daemon: ref.daemon.store) }
        let group = ref.group.id
        ref.daemon.send("close-screen-group") { _ = try await $0.closeScreenGroup(group) }
    }

    static func save(_ group: ScreenGroupID, daemon: DaemonService) {
        daemon.send("save-screen-group") { _ = try await $0.saveScreenGroup(group) }
    }

    static func unsave(_ group: ScreenGroupID, daemon: DaemonService) {
        daemon.send("unsave-screen-group") { _ = try await $0.unsaveScreenGroup(group) }
    }

    /// A new screen at the end of the group.
    static func newScreen(in ref: ScreenGroupRef) {
        let last = ref.members.last.flatMap { member in ref.workspace.screens.firstIndex { $0 === member } }
        ScreenCommands.create(in: ref.workspace, daemon: ref.daemon, content: ref.content,
                              spec: ScreenSpec(index: last.map { $0 + 1 }, group: ref.group.id))
    }

    /// The first of Chrome's colors no group in `workspace` uses yet.
    static func nextColor(in workspace: WorkspaceModel?) -> GroupColor {
        let used = Set(workspace?.screenGroups.compactMap(\.color) ?? [])
        return GroupColor.allCases.first { !used.contains($0.rawValue) } ?? .grey
    }
}
