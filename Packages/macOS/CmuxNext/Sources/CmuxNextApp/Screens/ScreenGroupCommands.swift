import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign

/// The one mutation path for screen groups (the daemon's `screen_group`
/// state resources), shared by the screen bar's chips and editor bubble,
/// the palette, context menus, shortcuts, and the CLI. Each change is one
/// daemon command on public screen ids.
@MainActor
enum ScreenGroupCommands {
    static func create(_ screens: [ScreenModel], in workspace: WorkspaceModel, name: String?, color: GroupColor?, daemon: DaemonService) {
        let ids = screens.compactMap(\.resourceID), color = (color ?? nextColor(in: workspace)).rawValue
        guard !ids.isEmpty else { return }
        daemon.send("screen_group.create") { _ = try await $0.createScreenGroup(ids, name: name, color: color) }
    }

    /// Adds screens after the group's last member.
    static func add(_ screens: [ScreenModel], to group: ScreenGroupID, daemon: DaemonService) {
        let ids = screens.compactMap(\.resourceID)
        guard !ids.isEmpty else { return }
        daemon.send("screen_group.add_screens") { try await $0.addScreens(ids, toGroup: group) }
    }

    static func remove(_ screens: [ScreenModel], daemon: DaemonService) {
        let ids = screens.compactMap(\.resourceID)
        guard !ids.isEmpty else { return }
        daemon.send("screen_group.remove_screens") { try await $0.removeScreensFromGroup(ids) }
    }

    static func update(_ group: ScreenGroupID, name: String? = nil, color: GroupColor? = nil, collapsed: Bool? = nil, daemon: DaemonService) {
        let color = color?.rawValue
        daemon.send("screen_group.update") { try await $0.updateScreenGroup(group, name: name, color: color, collapsed: collapsed) }
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

    static func ungroup(_ group: ScreenGroupID, daemon: DaemonService) {
        daemon.send("screen_group.ungroup") { try await $0.ungroupScreenGroup(group) }
    }

    /// Closes every member screen; the group goes with its last member.
    static func close(_ ref: ScreenGroupRef, services: AppServices) {
        ScreenCommands.close(ref.members, in: ref.workspace, daemon: ref.daemon, services: services)
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
