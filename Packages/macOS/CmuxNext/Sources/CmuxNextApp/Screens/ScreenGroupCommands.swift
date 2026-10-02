import Foundation
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextTabs

/// The one mutation path for screen groups (`screen-groups-v1`), shared by
/// the screen bar's chips and editor bubble, the palette, context menus,
/// shortcuts, and the CLI. Each change is one command to the daemon that
/// owns the workspace (`ScreenGroupRef.daemon`, `GroupOwnership`): a
/// protocol-v2 state operation with an idempotency key where the daemon
/// serves `state-resources-v1` (workspace-store ops, OWNERSHIP-PRINCIPLES),
/// else the raw command. Collapse state is shared store state (the daemon's
/// group record), like tab groups and Chrome's synced groups.
@MainActor
enum ScreenGroupCommands {
    static func create(_ screens: [ScreenModel], in workspace: WorkspaceModel, name: String?, color: GroupColor?, daemon: DaemonService) {
        let handles = screens.map(\.handle), color = (color ?? nextColor(in: workspace)).rawValue
        change("create-screen-group", .create(screens: screens.map(\.id), name: name, color: color), daemon: daemon) {
            _ = try await $0.createScreenGroup(handles, name: name, color: color)
        }
    }

    static func add(_ screens: [ScreenModel], to group: ScreenGroupID, index: Int? = nil, daemon: DaemonService) {
        let handles = screens.map(\.handle)
        // The v2 operation has no index: a placed add stays on the raw command.
        let state: DaemonConnection.ScreenGroupOperation? = index == nil ? .addScreens(group: group.rawValue, screens: screens.map(\.id)) : nil
        change("add-screens-to-screen-group", state, daemon: daemon) { _ = try await $0.addScreens(handles, toGroup: group, index: index) }
    }

    static func remove(_ screens: [ScreenModel], daemon: DaemonService) {
        let handles = screens.map(\.handle)
        change("remove-screens-from-screen-group", .removeScreens(screens.map(\.id)), daemon: daemon) {
            _ = try await $0.removeScreensFromGroup(handles)
        }
    }

    static func update(_ group: ScreenGroupID, name: String? = nil, color: GroupColor? = nil, collapsed: Bool? = nil, daemon: DaemonService) {
        let color = color?.rawValue
        change("update-screen-group", .update(group: group.rawValue, name: name, color: color, collapsed: collapsed), daemon: daemon) {
            _ = try await $0.updateScreenGroup(group, name: name, color: color, collapsed: collapsed)
        }
    }

    /// Collapses or expands. Collapsing a group that holds the shown screen
    /// first shows the nearest visible screen to its right, else its left
    /// (Chrome's rule, `TabGroupOrdering`, the same one pane tab strips use).
    static func setCollapsed(_ ref: ScreenGroupRef, _ collapsed: Bool) {
        if collapsed, let content = ref.content, let active = content.layoutModel.activeScreenID?.rawValue,
           ref.members.contains(where: { $0.id == active }) {
            let bar = content.screenBar.model
            let collapsedGroups = Set(bar.groups.filter(\.isCollapsed).map(\.id))
            if let next = TabGroupOrdering.selectionAfterCollapsing(CmuxNextTabs.TabGroupID(ref.group.id.rawValue), in: bar.orderedTabs,
                                                                   collapsed: collapsedGroups, selected: StripTabID(active)),
               next.rawValue != active {
                ScreenCommands.select(LayoutScreenID(next.rawValue), in: content)
            }
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
        change("ungroup-screen-group", .ungroup(group: group.rawValue), daemon: daemon) { _ = try await $0.ungroupScreenGroup(group) }
    }

    /// Sends one screen group change: the v2 state operation `state` with a
    /// fresh idempotency key when the daemon serves `state-resources-v1`,
    /// else the raw command `raw`.
    static func change(_ label: String, _ state: DaemonConnection.ScreenGroupOperation?, daemon: DaemonService,
                       raw: @escaping @Sendable (DaemonConnection) async throws -> Void) {
        guard let state, daemon.supports(DaemonCapabilities.shared.stateResources) else { return daemon.send(label, raw) }
        let key = idempotencyKey(label)
        daemon.send(label) { _ = try await $0.screenGroupState(state, idempotencyKey: key) }
    }

    /// `cmux-next-<label>-<uuid>`: unique per user intent, under 128 bytes.
    static func idempotencyKey(_ label: String) -> String {
        "cmux-next-\(label)-\(UUID().uuidString.lowercased())"
    }

    static func close(_ ref: ScreenGroupRef, services: AppServices) {
        for screen in ref.members { services.closedScreens.record(screen, in: ref.workspace) }
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

    /// The color a new screen group gets (`TabGroupOrdering.nextColor`).
    static func nextColor(in workspace: WorkspaceModel?) -> GroupColor {
        TabGroupOrdering.nextColor(used: workspace?.screenGroups.compactMap { $0.color.flatMap(GroupColor.init(rawValue:)) } ?? [])
    }
}
