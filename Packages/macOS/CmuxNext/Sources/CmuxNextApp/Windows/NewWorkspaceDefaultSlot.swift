import CmuxNextBridge
import CmuxNextSettings
import CmuxNextSidebar

/// `workspaces.newPlacement` for one new workspace whose entry point names
/// no place (Cmd-N, the palette, the sidebar's +, `cmux workspace new`, a
/// tab moved to a new workspace, a link or an agent opening one). Resolved once the daemon reports the
/// workspace, against the sidebar of the window that lists it, and written
/// by the row-drag path (`SidebarBridge.place`): personal order in the home
/// session, else the owning daemon's order. Either survives a relaunch and
/// shows in every window.
///
/// The rule: `top` is the first slot of the window's current workspace's
/// group when that one is in a group (Cmd-N in a group keeps the new one in
/// it, at the group's top, Lawrence 2026-10-28); else the first slot of the workspace's machine section, which
/// lists no pinned workspace (they show in the Pinned section above), above
/// every group, and right below the home workspace's row when the list shows
/// it. `afterCurrent` is right after the workspace the window showed
/// when the new one was asked for, inside its group when it has one; `top`
/// when that workspace is not in the section (pinned, Home, another machine,
/// none). `bottom` is the last slot of the current workspace's group; outside a
/// group it leaves the daemon's place, the end of the loose rows. So a new
/// workspace opened from inside a group stays in it under every value (cx-caoh).
struct NewWorkspaceDefaultSlot: Hashable, Sendable {
    var placement: NewWorkspacePlacement
    /// The workspace the window showed when the new one was asked for.
    var current: String?

    /// The slot for new workspace `id` in `section` of a window's `sections`;
    /// nil keeps the daemon's place. `home` is the home workspace's id.
    func slot(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?) -> WorkspaceSlot? {
        switch placement {
        case .bottom:
            if let current, current != id, current != home,
               WorkspaceSlot.bottom(anchor: current).position(moving: [id], section: section, in: sections)?.group != nil {
                return .bottom(anchor: current)
            }
            return nil
        case .afterCurrent:
            if let current, current != id, current != home,
               WorkspaceSlot.below(current).position(moving: [id], section: section, in: sections) != nil {
                return .below(current)
            }
            return Self.top(for: id, section: section, in: sections, home: home)
        case .top:
            if let current, current != id, current != home,
               WorkspaceSlot.top(anchor: current).position(moving: [id], section: section, in: sections)?.group != nil {
                return .top(anchor: current)
            }
            return Self.top(for: id, section: section, in: sections, home: home)
        }
    }

    /// The move the app sends once the daemon reports new workspace `id`, or nil when the daemon's
    /// create already put it at ``slot(for:section:in:home:)``: the daemon places every new workspace
    /// by `workspaces.newPlacement` in the commit that creates it (first below Home under `top`,
    /// last under `bottom`), so a second write would be a second state change and a second render
    /// for the same order (plans/cmux-next/sidebar-ordering-DESIGN.md). Only a slot the daemon does
    /// not know is moved to: inside the current workspace's group, after the window's current one.
    func move(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?) -> WorkspaceSlot? {
        guard let slot = slot(for: id, section: section, in: sections, home: home) else { return nil }
        if slot == Self.top(for: id, section: section, in: sections, home: home) { return nil }
        return slot
    }

    /// The slot for a new workspace made inside group `group` from the group itself (its header's
    /// +, a double-click in its empty part), whose workspace rows are `members` in order: its
    /// first slot under `top`, right below the window's current workspace under `afterCurrent`
    /// when that one is a member (else the first slot), its last slot under `bottom`.
    func slot(inGroup group: GroupID, members: [String]) -> WorkspaceSlot {
        let first = members.first.map { WorkspaceSlot.top(anchor: $0) } ?? .endOfGroup(group)
        switch placement {
        case .top: return first
        case .afterCurrent:
            if let current, members.contains(current) { return .below(current) }
            return first
        case .bottom: return .endOfGroup(group)
        }
    }

    /// First in the section, below a leading home row.
    private static func top(for id: String, section: SectionID, in sections: [SidebarRowSection], home: String?) -> WorkspaceSlot {
        let first = sections.first { $0.id == section }?.nodes.lazy.compactMap { node -> String? in
            guard case let .workspace(workspace) = node else { return "" }
            return workspace.id.rawValue == id ? nil : workspace.id.rawValue
        }.first
        if let home, first == home { return .below(home) }
        return .top(anchor: nil)
    }
}

/// Registering new workspaces for placement, outside `WindowManager` (its
/// type budget): the rule for a window, and the pending placement that
/// `WindowManager.applyPendingPlacements` resolves once the daemon reports
/// the workspace.
@MainActor
enum NewWorkspacePlacements {
    /// `workspaces.newPlacement` for a new workspace of window `windowID`
    /// (nil: the window reconcile gives it, the most recent open one), with
    /// the workspace that window shows now. Read it before the claim selects
    /// the new workspace.
    static func rule(for windowID: String?, in windows: WindowManager) -> NewWorkspaceDefaultSlot {
        let placement = windows.services.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementFallback
        let window = windowID ?? windows.registry.value.mostRecentOpen()
        return NewWorkspaceDefaultSlot(placement: placement, current: window.flatMap { windows.states[$0]?.workspaceID })
    }

    /// Places workspace `id` at `slot`, else by `byDefault`, in window
    /// `windowID` (nil: the window that lists it): now when it is mirrored,
    /// else once the daemon reports it. `then` runs after, with the sidebar.
    static func expect(_ id: String, in windowID: String?, slot: WorkspaceSlot? = nil, byDefault: NewWorkspaceDefaultSlot?,
                       then: (@MainActor @Sendable (String, any WorkspaceSpawnSidebar) -> Void)? = nil, windows: WindowManager) {
        guard slot != nil || byDefault != nil || then != nil else { return }
        windows.pendingPlacements[id] = PendingPlacement(window: windowID, slot: slot, byDefault: byDefault, then: then)
        if windows.services.machines.workspace(id: id) != nil { windows.applyPendingPlacements(live: [id]) }
    }

    /// The local home workspace (`workspace-kind-v1`), whose row `top` stays below.
    static func home(_ machines: MachineRegistry) -> String? {
        machines.local.store.workspaces.first { $0.kind == SidebarMapping.homeKind }?.id
    }

    /// The index a group formed for a new workspace takes (`createGroup`'s `index`, New Workspace in
    /// New Group): first under `workspaces.newPlacement` `top` (the default), else last (`Int.max`).
    /// The same rule as the Chief's subagent groups (`new_group_index` in optchat-chief workspaces.rs).
    static func newGroupIndex(_ services: AppServices) -> Int {
        newGroupIndex(for: services.settings?.snapshot.newWorkspacePlacement ?? CmuxConfigSnapshot.newWorkspacePlacementFallback)
    }

    static func newGroupIndex(for placement: NewWorkspacePlacement) -> Int { placement == .top ? 0 : .max }
}
